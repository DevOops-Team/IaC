# 개인 PC에서 수동 진단·노드 서비스 복구

기준: 2026-11-09. [ADR-11](https://devoops-team.atlassian.net/wiki/spaces/GPUF/pages/11730951)은 **개인 PC에서 필요할 때 수동 실행**을 채택했다. 전용 Ansible VM과 상시 점검 systemd timer는 사용하지 않는다. 이 저장소 변경은 실제 장비의 timer 중지나 클러스터 적용을 수행한 것이 아니다.

## 역할·실행 범위

| 구성 | 실행 위치·방식 | 담당 범위 |
|---|---|---|
| Ansible·watcher.py | 개인 PC, 담당자가 한 사이클씩 수동 호출 | 온프레 VM 6대 진단, 조건을 통과한 단일 노드 kubelet/containerd 시작 |
| 학습 복구 컨트롤러 | 온프레 Kubernetes `platform/recovery-controller` | Kafka 사건 → 복구 판단·세대 전환·스케줄링 재배치 요청 |
| 인증서 갱신 timer | 대상 control-plane 노드 | 기존 Kubespray 인증서 갱신. ADR-11의 Ansible 상시 점검 timer와 별개이며 유지 |

```text
담당자가 개인 PC에서 명령 실행
 → API·노드 조회 + Ansible SSH 진단
 → 분류·latest.json 기록
 → 결과 검토 후 --apply로 다시 호출한 경우에만 복구 후보 검사
 → 조건을 통과하면 단일 노드 containerd → kubelet 시작
 → 서비스 active·Node Ready 확인
```

PC를 끄거나 명령을 실행하지 않으면 Ansible 진단·복구가 실행되지 않는다. Kubernetes의 Pod 재시작, 노드 인증서 갱신, 별도 학습 복구 컨트롤러는 이 수동 호출과 구분한다. 개인 PC를 control-plane/worker inventory에 넣지 않는다.

## 준비

개인 PC의 Python 3.12+·Git·kubectl·SSH 환경에서 `scripts/setup-kubespray.sh`로 고정 버전 Ansible/Kubespray를 준비한다. macOS/Linux를 사용하며 Windows는 WSL/Linux 환경에서 실행한다. SSH known_hosts를 검증하고 host key 확인을 끄지 않는다. VM별 SSH 계정은 VM 이름(master1~3, worker1~3)이며 실제 주소와 호스트 배치는 [TEAM-CONTRACT.md](TEAM-CONTRACT.md)를 따른다.

```sh
cd gpu-iac/ansible
PYTHON_BIN=python3.12 ./scripts/setup-kubespray.sh
cp recovery.example.yml recovery.local.yml
```

manager_context·kubeconfig_file·ssh_private_key_file을 개인 PC의 실제 값으로 입력한다. 상대 경로는 ansible 디렉터리 기준이다. kubeconfig가 관리 API `https://172.30.0.120:6443`을 가리키는지 확인한다. 조사는 readyz·kube-system namespace·Node·전체 namespace Pod 읽기와 VM SSH/sudo 권한이 필요하다. watcher는 비대화형 subprocess로 실행하므로 필요한 SSH/sudo 인증이 입력 대기 없이 동작해야 하며, 불가능하면 조치하지 않는다. 비밀정보는 Git에 넣지 않는다.

## 1. 진단만 수동 실행

```sh
.venv/bin/python scripts/recovery/watcher.py --config recovery.local.yml
```

기본 auto_repair_enabled=false이며 --apply 없이 호출하면 설정이 true여도 변경하지 않는다. API 불통 시에도 SSH 조사는 시도하지만 원인을 단정해 복구하지 않는다. 기본 기록은 `.state/recovery/latest.json`, `state.json`, `runs/<run-id>`이며 최근 20개를 보관한다. Secret·환경변수·앱 로그·subprocess stderr는 기록하지 않는다. 자격증명·도구 실행 오류나 손상된 state 파일은 종료 코드 1로 중단한다.

## 2. 검토 후 제한된 복구를 수동 호출

실제 진단 결과와 대상 클러스터를 확인하고 expected_cluster_uid를 기록한다.

```sh
kubectl --context 실제context get namespace kube-system -o jsonpath='{.metadata.uid}'
```

recovery.local.yml의 auto_repair_enabled를 true로 바꾸고 **담당자가 다음 명령을 직접 실행**한다. 이 설정 이름은 기존 호환성을 유지한 것으로 상시 자동 실행을 뜻하지 않는다.

```sh
.venv/bin/python scripts/recovery/watcher.py --config recovery.local.yml --apply
```

한 번의 명령은 한 사이클뿐이다. 기본 동일 장애 3회 연속 확인은 사람이 수행한 진단/복구 호출 사이의 상태로 누적하며 timer가 호출하지 않는다. 각 호출에서 수집한 probe는 max_probe_age_seconds 기본 300초 이내의 최신 자료여야 한다. 호출 사이의 최대 간격을 제한하는 설정은 아니므로, 이전 관찰이 오래됐다면 담당자가 최근 상태를 다시 충분히 확인한다. 조건을 줄이거나 상태를 지워 즉시 복구시키지 않는다.

다음 조건을 모두 확인한다.

- --apply와 auto_repair_enabled=true, 확인된 inventory, 3 control-plane + 3 worker.
- API readyz·kube-system UID·Node 이름·InternalIP 일치, 6대 SSH 조사 성공 및 최신 상태.
- 한 노드만 NotReady이고 kubelet/containerd가 중단, 나머지 5개 Ready.
- 대상이 cordon/삭제/유지보수 상태가 아니고 메모리·디스크 여유·Pressure 조건 충족.
- 기존에 설치·enabled인 unit이 inactive/failed. disabled/masked·미설치·설정 손상은 건드리지 않음.
- 기본 3회 연속 확인·30분 쿨다운·미해결 이전 복구 차단 상태 검사.

기본 allow_control_plane_service_start=false다. 명시적으로 허용해도 기존 API와 다른 5개 노드 정상 조건이 필요하다. 복구는 필요한 서비스의 state=started이며 정상 서비스를 재시작하지 않는다. 설정·패키지·Pod·etcd 멤버·인증서를 변경하지 않는다. 실행 전에 시도/차단 상태를 영속 기록하여 PC 프로세스가 중단돼도 같은 조치를 즉시 반복하지 않는다.

## 3. 상태 보존·실행 PC 인계

잠금은 같은 state_dir의 동시 실행만 막는다. **여러 PC 사이의 분산 잠금이 아니다.** 한 번에 한 담당 PC에서만 복구한다. 다른 PC로 옮길 때 이전 실행이 끝났는지 확인하고 state.json·쿨다운·미해결 시도·maintenance와 자격증명을 안전하게 인계한다. 상태를 복원할 수 없으면 관찰 전용으로 시작하여 미해결 시도를 사람이 확인한다. state 파일을 삭제해 재시도 제한을 우회하지 않는다.

```sh
mkdir -p .state/recovery
touch .state/recovery/maintenance
# 유지보수 종료 후에만
rm .state/recovery/maintenance
```

maintenance가 있으면 보고만 하고 연속 관찰을 초기화한다. 메인 서버 장애 시에도 개인 PC에서 진단할 수 있으나 네트워크·API·정족수·대상 VM 가용성이 없으면 서비스 복구는 보류한다. 물리 서버 전원 복구·VM 재생성·NFS/Proxmox HA는 수행하지 않는다.

## 4. 이전 전용 VM·timer의 처리

runner inventory·runner.example.yml·recovery-runner role·systemd 템플릿은 제거했다. 기존 `playbooks/recovery/install-runner.yml` 경로는 안내와 함께 실패하며 아무것도 설치하지 않는다. Git 이력으로 이전 구현을 조회할 수 있지만 현재 운영 경로가 아니다.

과거 장비에 직접 설치한 적이 있는 경우에만 담당자가 해당 **옛 실행기에서** 아래 작업을 한다. 개인 PC나 모든 Kubernetes 노드에 실행하는 명령이 아니다.

```sh
sudo systemctl disable --now gpu-k8s-recovery.timer
sudo systemctl stop gpu-k8s-recovery.service
systemctl is-active gpu-k8s-recovery.timer gpu-k8s-recovery.service
```

실행 중 조치가 끝났는지 확인한 뒤 기존 state_dir와 접근 자격증명을 보존·인계한다. 새 PC에서 읽기 전용 진단부터 시작한다. 이 저장소 변경만으로 기존 timer가 중지되지는 않는다. **`k8s-certs-renew.timer`는 중지하지 않는다.** 해당 timer는 [CERTIFICATES.md](CERTIFICATES.md)의 노드 인증서 갱신용이다.

## 파일과 분류

| 경로 | 용도 |
|---|---|
| scripts/recovery/watcher.py·core.py | 수동 한 사이클·분류·조건 판단·잠금·상태 기록 |
| playbooks/recovery/diagnose.yml·roles/recovery-probe | 읽기 전용 VM 조사 |
| playbooks/recovery/repair-services.yml·roles/recovery-services | 허용된 한 노드의 서비스 시작·Ready 확인 |
| playbooks/recovery/verify-controller.yml | 별도 학습 복구 컨트롤러의 배포 상태 조회 |
| recovery.example.yml | 개인 PC 입력 예시 |

APP_WORKLOAD_ISSUE·API_NETWORK_OR_AUTH_FAILURE·SSH_OR_PROBE_UNAVAILABLE·NODE_OR_CNI_FAILURE·RESOURCE_PRESSURE·SERVICE_INSTALLATION_OR_CONFIG_FAILURE·CONTROL_PLANE_REVIEW_REQUIRED·MULTI_NODE_FAILURE는 원인 확인·담당 인계 대상이다. CONFIRMED_SERVICE_STOP만 위 조건에 따라 시작한다. Calico를 포함한 Pod 컨테이너 종료/liveness 실패는 Kubernetes 기본 정책으로 처리하며 Ansible이 Pod를 삭제하지 않는다.

## 로컬 검증

```sh
.venv/bin/python -m unittest discover -s scripts/recovery/tests -v
.venv/bin/ansible-playbook playbooks/recovery/diagnose.yml --syntax-check
.venv/bin/ansible-playbook playbooks/recovery/repair-services.yml --syntax-check
```

정책·가짜 CLI 테스트는 실제 SSH·systemd·Kubernetes를 호출하지 않는다. 실제 장애 주입·복구는 별도 검증한다.
