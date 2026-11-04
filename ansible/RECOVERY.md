# Kubernetes 장애 감지·분류·제한된 서비스 복구

현재 물리 장비와 VM이 살아 있고 SSH 접근이 가능한 범위를 다룹니다. 실제 클러스터에 실행하거나 systemd timer를 설치하지 않았습니다.
GitLab 설치는 필요 없습니다. 기존 GitHub/gpu-iac와 메인 서버의 전용 Ansible Ubuntu VM을 사용합니다. 이 VM은 Kubernetes 밖에 있으며 Proxmox 호스트·master1과 별도입니다.

## 흐름

```text
메인 서버 → 전용 Ansible VM의 systemd timer
    ↓
watcher.py 한 사이클 실행·로컬 잠금
    ├─ API readyz, kube-system UID, Node·Pod 상태 조회
    └─ Ansible로 6개 VM의 SSH·systemd·메모리·디스크 읽기 전용 조사
    ↓
core.py가 장애 분류
    ├─ 앱 CrashLoopBackOff·이미지 오류·Unschedulable → 보고만
    ├─ API·네트워크·인증·SSH 문제 → 보고만
    ├─ 다중 노드·자원 부족·설정/설치 문제 → 보고만
    └─ 한 노드의 enabled kubelet/containerd 중단 → 제한적 복구 후보
    ↓
연속 관찰·식별·자원·유지보수·쿨다운 검사
    ↓ (명시적으로 자동 조치를 켠 경우만)
한 노드만 repair-services.yml 실행
    ↓
서비스 active + Kubernetes Node Ready 확인
```

CrashLoopBackOff는 컨테이너가 반복 종료되어 Kubernetes가 재시도 간격을 늘리고 있는 상태입니다. 앱 로그·설정·이미지·자원 등의 원인을 확인해야 하며 이 감지기는 앱 Pod를 삭제하거나 무조건 재시작하지 않습니다.

## 파일

| 파일 | 역할 |
|---|---|
| scripts/recovery/watcher.py | CLI·Ansible 호출, 주기 실행 한 사이클, 잠금·기록·복구 분기 |
| scripts/recovery/core.py | 외부 실행 없는 분류·복구 여부 판단 |
| playbooks/recovery/diagnose.yml | 6개 VM을 읽기 전용 조사 |
| roles/recovery-probe | unit 상태·디스크·메모리 조사 스크립트 |
| playbooks/recovery/repair-services.yml | 승인된 한 노드에서 서비스 시작·Ready 검증 |
| roles/recovery-services | 매번 실제 식별/상태를 재확인한 뒤 containerd→kubelet 순서로 필요한 unit만 시작 |
| playbooks/recovery/install-runner.yml | 메인 서버 전용 Ubuntu VM에 systemd unit/timer 설치 |
| roles/recovery-runner | 실행기 조건·경로 점검, timer 구성 |
| recovery.example.yml | 감지기 입력 예시; recovery.local.yml로 복사 |
| scripts/recovery/tests | 분류 정책과 가짜 CLI를 이용한 전체 분기 테스트 |

이 플레이북들은 site.yml에 자동 포함하지 않습니다. 기본 설치·GitOps bootstrap과 장애 대응을 분리합니다.

## 자동 조치의 조건

다음 조건을 모두 만족해야 합니다.

- 실행에 --apply를 지정하고 recovery.local.yml의 auto_repair_enabled도 true.
- 확인된 inventory이며 3 control-plane + 별도 worker 3대 구성.
- API readyz 정상, kube-system UID가 지정한 expected_cluster_uid와 일치.
- API Node 이름·InternalIP가 inventory와 일치하고, 6대 모두 SSH 조사가 성공·최신 상태.
- 한 노드만 NotReady이면서 해당 노드의 kubelet/containerd 중단이 관찰됨. 나머지 5개 노드는 Ready.
- 대상은 cordon/삭제 중이 아니고, Disk/Memory/PIDPressure가 없고 메모리·디스크 여유가 기준 이상.
- 중단된 unit은 기존에 설치되고 enabled 상태이며 inactive 또는 failed. disabled/masked/전환 중인 unit은 건드리지 않음.
- 동일 후보가 기본 3회 연속 관찰됨. 복구 시도 간 기본 30분 쿨다운.
- maintenance 파일이 없고, 미해결 이전 복구 시도로 회로가 차단되지 않았음.

기본 allow_control_plane_service_start=false이므로 자동 조치는 worker 서비스에 한정됩니다. control-plane에 true를 지정해도 기존 API와 다른 5개 노드가 정상일 때만 단순 서비스 시작을 허용합니다. etcd 멤버 변경·스냅샷 복원·인증서 재생성·노드 재가입은 수행하지 않습니다.

복구를 명령하기 **전에** state.json에 시도·차단 상태를 저장합니다. 실행기가 중간 종료돼도 다음 주기에 같은 서비스를 계속 재시작하지 않습니다. 정상 인프라 상태를 3회 연속 확인하면 차단이 해제되지만 마지막 시도의 쿨다운은 유지됩니다. 자동 복구가 실패하고 장애가 남으면 사람이 원인을 해결해야 합니다.

## 1. 진단만 실행

Ansible 제어 환경과 VM SSH·sudo를 준비합니다. timer 실행에는 비밀번호 입력 없이 실행 가능한 자격증명이 필요합니다. SSH known_hosts는 검증 후 미리 등록하며 host key 확인을 끄지 않습니다.

```bash
cd gpu-iac/ansible
cp recovery.example.yml recovery.local.yml
```

실제 manager_context, kubeconfig_file, ssh_private_key_file을 입력합니다. 상대 경로는 ansible 폴더 기준입니다.
관리 API에는 readyz, kube-system namespace, Node와 전체 namespace Pod의 읽기 권한이 필요합니다. SSH/sudo는 VM 상태 조사·명시한 systemd unit 시작에 필요한 권한을 준비합니다. 자격증명·개인키는 Git에 올리지 않습니다.

```bash
.venv/bin/python scripts/recovery/watcher.py --config recovery.local.yml
```

--apply 없이 실행하면 auto_repair_enabled가 true라도 조치하지 않습니다. API가 죽어도 Ansible의 SSH 조사는 시도하고 결과를 보고합니다.
기본 기록은 .state/recovery/latest.json, state.json, runs/<run-id>입니다. 디렉터리·파일 접근을 제한하고 기본 최근 20개 실행만 유지합니다. Pod/노드·unit 상태만 기록하고 Secret·환경변수·애플리케이션 로그·subprocess stderr는 저장하지 않습니다. Pod 읽기 권한이 없어도 노드 조사는 가능하지만 앱 진단 결과는 비어 있을 수 있습니다.
예상치 못한 도구 실행 오류·자격증명 오류·손상된 state 파일은 종료 코드 1로 중단하며 추가 조치를 수행하지 않습니다. API 장애 분류는 네트워크/인증/제어층 장애의 원인을 단정하지 않습니다.

## 2. 필요한 경우 자동 조치 켜기

먼저 실제 진단 결과를 검토하고 테스트 클러스터에서 검증합니다. kube-system UID는 다음 조회 또는 latest.json에서 확인할 수 있습니다.

```bash
kubectl --context 실제context get namespace kube-system -o jsonpath='{.metadata.uid}'
```

recovery.local.yml에 expected_cluster_uid를 기록하고 auto_repair_enabled=true로 설정합니다. inventory의 onprem_inventory_confirmed도 true여야 합니다.

```bash
.venv/bin/python scripts/recovery/watcher.py --config recovery.local.yml --apply
```

한 번 호출하면 한 사이클만 수행합니다. 기본 3회 연속 확인 조건 때문에 최초 한 번의 호출로 즉시 변경하지 않습니다. 진단 주기에서 계속 같은 장애가 확인될 때 조치합니다.
복구는 systemd state=started이며 정상 동작 중인 서비스를 재시작하지 않습니다. 설정 파일·패키지·Pod spec을 변경하지 않습니다.

## 3. 주기 실행기를 설치

메인 서버(Proxmox)에 **Ansible 전용 Ubuntu VM**을 만들고 그 VM에 gpu-iac를 내려받습니다. ADR-3의 초기 계획은 2 vCPU / RAM 2GB / 디스크 20GB입니다. 기존 master1·worker1과 별개이며 Kubernetes에 가입시키지 않습니다. Proxmox 호스트 자체에 Ansible을 설치하지 않습니다.

메인 서버의 계획 총량은 이 VM 포함 16 vCPU / RAM 44GB / 가상 디스크 420GB입니다. 실제 호스트 부하·스토리지 여유는 설치 전에 확인합니다. 물리 호스트 표시는 배치 계획이며 아래 검사는 KVM 게스트·hostname·최소 메모리/vCPU·노드 IP 비중복을 확인합니다. 물리 배치는 Proxmox에서도 확인해야 합니다.

Terraform/proxmox 폴더에는 VM 생성 구현이 아직 없습니다. VM 생성·Ubuntu/Python 3.12+·automation 계정·Git/kubectl·SSH 접근을 먼저 준비하고, 해당 사용자로 /opt/gpu-iac에 checkout 후 `PYTHON_BIN=python3.12 ./scripts/setup-kubespray.sh`를 실행해 Ansible 가상환경을 준비합니다. 설치 플레이북은 이미 준비된 실행 환경에 timer를 설치합니다.

- 기존 실행 사용자(예: automation)를 준비하고 checkout·Ansible 가상환경·kubectl·kubeconfig·SSH 키 접근을 확인합니다.
- 실행 사용자로 먼저 진단 명령을 성공시킵니다. timer가 비밀번호를 물을 수 없으므로 필요한 비대화형 SSH/sudo 접근을 준비합니다.
- recovery.local.yml의 state_dir와 아래 recovery_runner_state_dir가 같아야 합니다. /opt/gpu-iac 기준 예시는 /opt/gpu-iac/ansible/.state/recovery입니다.

```bash
# 메인 서버의 전용 Ansible VM 안에서 실행
cp runner.example.yml runner.local.yml
hostname
# runner.local.yml의 expected_hostname을 위 결과로 설정하고 confirmed=true로 변경
.venv/bin/ansible-playbook \
  -i inventory/onprem/hosts.yaml -i inventory/runner/hosts.yaml \
  playbooks/recovery/install-runner.yml -e @runner.local.yml \
  --ask-become-pass
```

이 명령은 실제 systemd timer를 설치·활성화하므로 Linux 관리 실행기에서 명시적으로 실행합니다. Ubuntu KVM 게스트가 아니거나 확인한 hostname이 다르거나 로컬 IP가 Kubernetes 노드 IP와 겹치면 중단합니다. 실행기 inventory를 Kubespray 설치에 추가하지 않습니다.
서비스는 --apply로 호출하지만 config의 auto_repair_enabled 기본값은 false이므로 최초에는 관찰만 합니다. 기본 부팅 후 90초부터 시작하고, 한 사이클 완료 후 60초마다 다시 실행합니다. 작업 시간이 길면 주기가 길어집니다. 잠금으로 동시 실행을 방지합니다.

```bash
systemctl status gpu-k8s-recovery.timer
journalctl -u gpu-k8s-recovery.service
```

유지보수 중에는 실제 state_dir에 maintenance 파일을 만듭니다. 이 파일이 있으면 감지·보고만 하고 연속 복구 확인 횟수를 초기화합니다. 유지보수 종료 후 제거하면 새로운 연속 관찰을 거칩니다.

```bash
touch /opt/gpu-iac/ansible/.state/recovery/maintenance
# 유지보수 종료 후
rm /opt/gpu-iac/ansible/.state/recovery/maintenance
```

## 메인 서버·실행기 자체 장애

- 실행기 VM만 재부팅: enabled timer가 부팅 후 다시 시작합니다. VM 디스크의 state.json·쿨다운·미해결 시도 기록을 유지합니다. 상태 파일을 지우고 자동 조치를 다시 켜지 않습니다.
- 메인 서버 전체 중단: master1·worker1·DB·Kafka와 실행기가 함께 멈춥니다. 실행기가 자기 물리 호스트를 되살릴 수 없고 외부 Monitoring도 별도로 확인해야 합니다.
- 현재 단계에서는 생존 Proxmox 호스트에서 기존 VM의 디스크·설정 접근과 용량을 확인한 뒤 운영자가 실행기를 재시작합니다. 원래 실행기의 종료/fencing을 확인하고 같은 디스크·식별정보·상태 기록을 유지해 중복 실행을 막습니다. 자동 복구 전 읽기 전용 진단으로 클러스터 식별·네트워크·자격증명을 다시 확인합니다.
- 향후 Proxmox HA 자동 재시작은 NFS에 **실제 VM 디스크**가 있고 생존 노드가 접근 가능하며 정족수·fencing·브리지·대상 자원이 검증된 경우에만 적용합니다. NFS가 메인 서버에서 제공되면 메인 서버 장애 대책이 되지 않습니다. NFS 연결만으로 VM이 자동 분산되지 않습니다. 이 저장소는 아직 HA 등록·VM 이전을 수행하지 않습니다.
- 코드·inventory는 Git으로 복구하고 키·kubeconfig는 별도 보안 백업으로 복구합니다. 새 실행기를 만들 때 상태 기록도 복원하고, 복원 불가능하면 관찰 전용으로 시작해 사람이 미해결 시도를 확인합니다. 노드별 서비스 자동 복구와 물리 서버 HA는 서로 다른 계층입니다.

## 분류별 담당

| 분류 | 다음 작업 |
|---|---|
| APP_WORKLOAD_ISSUE | 앱 로그·이미지·설정·자원 확인; GitOps/앱 담당 |
| API_NETWORK_OR_AUTH_FAILURE | API 서버·VIP·라우팅·인증 확인; 서비스 자동 변경 안 함 |
| SSH_OR_PROBE_UNAVAILABLE | VM·SSH·sudo·시간 동기화·실행 환경 확인 |
| NODE_OR_CNI_FAILURE | kubelet/containerd가 active라면 CNI·노드 로그 등 별도 진단 |
| RESOURCE_PRESSURE | 메모리·디스크·PID 부족 원인 해결; 자동 삭제/재시작 안 함 |
| SERVICE_INSTALLATION_OR_CONFIG_FAILURE | 패키지·unit·설정 손상 여부 점검; Kubespray 갱신/복구 절차 검토 |
| CONTROL_PLANE_REVIEW_REQUIRED / MULTI_NODE_FAILURE | 제어층·정족수 확인, 전용 복구 runbook 사용 |
| CONFIRMED_SERVICE_STOP | 위 모든 조건 충족 시 선택된 unit만 시작·Ready 검증 |

전역 API 장애, etcd 손상·정족수 상실, VM 재생성, Terraform·Proxmox 작업, 전체 Kubespray 재설치, Argo 강제 sync/Pod 삭제는 자동 수행하지 않습니다. 기존 별도 복구 컨트롤러의 학습 재시작 판단과도 구분합니다.

## 로컬 검증

```bash
.venv/bin/python -m unittest discover -s scripts/recovery/tests -v
.venv/bin/ansible-playbook playbooks/recovery/diagnose.yml --syntax-check
.venv/bin/ansible-playbook playbooks/recovery/repair-services.yml --syntax-check
.venv/bin/ansible-playbook -i inventory/onprem/hosts.yaml -i inventory/runner/hosts.yaml playbooks/recovery/install-runner.yml -e @runner.example.yml --syntax-check
```

정책 테스트와 가짜 CLI 통합 테스트는 실제 SSH·systemd·Kubernetes를 호출하지 않습니다. 실제 systemd 서비스/자원 압박/네트워크 단절을 다루는 복구 실험은 별도 테스트 환경에서 검증해야 합니다.


## Pod 내부 프로세스 복구

Calico를 포함한 Pod의 컨테이너 종료·liveness 실패는 Kubernetes 기본 재시작으로 처리합니다. 별도 Calico Pod 삭제 복구와 3회 재생성 카운터는 제거했습니다. 외부 watcher는 kubelet/containerd 서비스 복구만 담당합니다. 이전 state.json에 남은 calico 기록은 읽거나 실행에 사용하지 않습니다. Kubernetes liveness failureThreshold=3은 연속 실패 3회 후 재시작을 뜻하며, 총 재시작 횟수를 3회로 제한하지 않습니다.
