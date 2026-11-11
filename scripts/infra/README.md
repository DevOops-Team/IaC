# AWS 인프라 수동 ON / OFF

사용자 로컬 Windows PowerShell에서 실행하는 운영 스크립트. 학습 제출은 온프레 프론트엔드가 담당하며 이 스크립트는 AWS 실행 환경을 준비하거나 철거한다.

**현재 상태: 구현 및 읽기 검증 단계. 실제 ON/OFF 통합 검증 전.** 관리 클러스터의 Kueue 및 워커 배포 절차가 아직 없으므로 기본 설정으로 ON/OFF를 실행하면 변경 전에 중단한다. 미완성 상태에서 Terraform만 실행하고 학습 준비 완료로 표시하지 않는다.

## 범위

| 명령 | 동작 |
| --- | --- |
| `status` | AWS 계정, EKS 상태, CPU 희망 수, GPU EC2 수, 관리 클러스터의 작업 기록/잠금 조회 |
| `on` | 큐 신규 승인 보류 → network plan 검토/적용 → 주 pfSense VPN 갱신 → 양쪽 터널/BGP 확인 → Karpenter·NVIDIA 플러그인·스케줄링 복원 → MultiKueue 자격 증명 교체 → 큐 재개 |
| `off` | 신규 승인 보류 → 실행/예약 작업 확인 → GPU NodePool 제거 및 NodeClaim/실제 EC2 종료 확인 → AWS VPN 비활성화 → network destroy plan 적용 → EKS 부재 확인. 큐는 보류 유지 |

OFF는 EKS·CPU 노드·VPC·NAT·VPN 등 **network 스택을 삭제**한다. 이 리소스들은 전원 스위치처럼 일괄 정지할 수 없어서 재생성 방식을 사용한다. bootstrap/data/identity 스택은 실행 대상에서 제외하며 state S3, 체크포인트/모니터링 S3, DynamoDB, 온프레 IAM/Roles Anywhere를 유지한다. 남아 있는 서비스 사용료·저장료까지 0원이 되는 것은 아니다.

## 준비 및 실행

필요 도구: Windows PowerShell 5.1 이상, AWS CLI v2, Terraform, OpenSSH, Python 3. 로컬 Python 외부 패키지 불필요. `master1`에는 Python3, kubectl, `~/.local/bin/helm` 및 관리 클러스터 kubeconfig 필요. `master1`, `pve4` SSH 별칭과 기존 호스트 키 등록 필요.

저장소 루트의 기존 PowerShell에서:

```powershell
Copy-Item scripts/infra/config.example.json scripts/infra/config.local.json
aws sso login --profile devoops
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/infra/infra.ps1 status
```

스케줄링 담당자와 아래 값을 확정한 다음 `config.local.json`에 반영한다.

| 설정 | 필요한 값 |
| --- | --- |
| `clusterQueues` | 관리 클러스터에서 `eks-a`로 작업을 보내는 ClusterQueue 이름 목록. 다른 워커까지 공유하는 큐는 보류 영향 확인 필요 |
| `workerBootstrapScript` | master1에 있는 실행 가능한 파일의 절대 경로. EKS에 Kueue·JobSet·워커 큐/리소스 설정을 복원하는, 버전 관리된 멱등 스크립트 |
| `workerDeployments` | 복원 후 확인할 `namespace/deployment` 목록. Kueue·JobSet 컨트롤러 포함 |
| `workerClusterQueues`, `workerLocalQueues` | 워커 ClusterQueue 이름 및 `namespace/LocalQueue` 목록. 각각 `Active=True` 확인 후 관리 큐 재개 |

bootstrap 스크립트에는 일시적인 워커 `KUBECONFIG`와 `EKS_CONTEXT`를 환경 변수로 제공한다. 반드시 이 대상만 사용하고 관리 클러스터의 기본 kubeconfig를 수정하지 않는다. kubeconfig 내용·토큰을 출력하거나 보관하지 않는다. 스크립트 종료 제한 10분, 각 Helm 대기 제한 8분. 토큰 만료/실패 시 큐는 보류 유지하며 원인 해결 후 재실행한다.

관리 클러스터에는 `MultiKueueCluster/eks-a`가 이미 있어야 하고 `spec.kubeConfig`가 `locationType: Secret`, `location: eks-a-kubeconfig`여야 한다. 준비 상태는 이 리소스의 `Active=True`까지 확인한다. 본 스크립트가 생성하는 워커 RBAC/토큰은 기존 `ansible/roles/multikueue-remote/files/rbac.yaml` 규약을 따른다.

**GitOps 소유권:** Argo CD가 관리하는 ClusterQueue는 현재 중단한다. Argo가 `stopPolicy`를 원복하면 보류 중 새 작업이 들어올 수 있다. 큐의 stopPolicy를 누가 관리할지 담당자와 정한 뒤 구현을 확장해야 한다. 라벨을 임의 제거해 우회하지 않는다. 대기 중 요청 자체를 보관/조회하는 프론트엔드·백엔드 로직은 별도 구현 범위다.

```powershell
# 읽기 사전검증. 준비값이 없으면 오류로 중단, 변경 없음.
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/infra/infra.ps1 on -WhatIf

# 준비/통합 검증이 끝난 뒤 수동 실행. plan과 apply 출력은 같은 창에 표시.
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/infra/infra.ps1 on
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/infra/infra.ps1 off
```

실행 계정 `354363695096`, 리전 `us-east-2`, 대상 `devoops-prod-eks-a`, S3 backend 키 `prod/network/terraform.tfstate`를 검증한다. ON에서 리소스 교체/삭제가 필요하면 중단하고 별도로 plan을 검토한다. 일반 콘솔 변경으로 CPU 노드를 0대로 줄였더라도 ON apply는 코드의 희망 수로 복구할 수 있다.

## 안전한 종료와 실패 복구

- 관리 큐에 `Hold` 적용. `HoldAndDrain`을 사용하지 않으며 이미 승인/예약된 작업이 있으면 중단하고 기존 큐 정책 복원.
- 워커의 실행 중 Job/JobSet, 학습 namespace의 미완료 Pod, 다른 namespace의 GPU 요청 Pod가 있으면 중단. PVC 또는 LoadBalancer Service/Ingress가 있으면 보관/정리 절차를 먼저 마련하도록 중단.
- GPU 노드의 finalizer는 강제 삭제하지 않는다. GPU 정리나 실제 EC2 종료 확인에 실패하면 CPU/Karpenter/EKS를 유지.
- 인프라 변경이 시작된 뒤 실패하면 큐는 보류 유지. `status`로 상태 확인 후 원인을 해결하고 같은 명령 재실행. 자동 destroy 롤백 없음.
- 관리 클러스터 `kube-system/devoops-eks-a-lifecycle` ConfigMap에 잠금과 이전 큐 정책/단계 보관. 동시 실행 차단. 비정상 PC 종료 후 잠금은 자동 탈취하지 않는다. **다른 실행이 없음을 확인한 뒤** 해당 ConfigMap의 `data.owner`만 비우고 재실행. ConfigMap 자체를 삭제하면 복구용 큐 정책을 잃는다.
- EKS가 수동으로 사라졌는데 정상 GPU 정리 기록이 없으면 OFF 차단. EC2·네트워크 잔여 자원과 state를 따로 확인해야 한다.
- 운영자가 학습 리소스를 직접 생성하거나 별도 도구가 큐 보류를 우회하면 이 스크립트만으로 경쟁을 방지할 수 없다. 실행 중 수동 제출/큐 수정 금지 필요.

## VPN과 비밀정보

현재 주 pfSense `.2`의 AWS 전용 Phase1/2 두 개와 FRR 이웃만 갱신한다. 주 방화벽이 정상이고 `pve4` SSH 경로를 사용할 수 있어야 한다. CARP·WAN·LAN·관리 SSH 설정은 변경하지 않는다. 대기 방화벽 `.3`의 VPN 전환/동기화는 이 스크립트의 검증 범위에 포함되지 않는다.

새 터널 값은 AWS API에서 읽으며 공인 IPv4는 pve4에서 조회한다. pfSense 변경 전 XML을 방화벽 내부 `/root/devoops-vpn-backups`에 0600으로 백업하고 해시 검증한다. 이 파일에는 비밀정보가 있어 저장소에 복사하지 않는다. SSH는 알려진 pve4 호스트 키와 설정된 pfSense 키 지문을 검증한다.

Terraform plan에는 비밀정보가 포함될 수 있다. 로컬 사용자·SYSTEM만 접근 가능한 임시 폴더에 생성하고 정상/오류 종료 시 삭제한다. PC가 강제 종료되면 남은 `%LOCALAPPDATA%/DevOops/infra-runtime`의 plan 파일을 점검한다. EKS 일시 토큰은 SSH stdin으로 전송하고 master1 `/dev/shm`의 0700 디렉터리/0600 파일에만 임시 기록한다. `config.local.json`은 Git 제외.

## 검증 및 후속 작업

```powershell
python -m unittest discover -s scripts/infra/tests -v
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/infra/tests/guards.ps1
```

실제 비용 발생 ON→학습 준비 확인→실행 작업 존재 시 OFF 거부→유휴 OFF→재생성 후 MultiKueue 재연결 검증은 스케줄링 배포 준비 뒤 함께 진행한다. 지정 시간 자동 OFF와 GPU 학습 제출/펜싱 로직은 이번 범위에서 제외.
