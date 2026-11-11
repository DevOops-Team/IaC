# AWS 인프라 수동 ON / OFF

사용자 로컬 Windows PowerShell에서 실행하는 운영 스크립트. 학습 제출은 온프레 프론트엔드가 담당하며 이 스크립트는 AWS 실행 환경을 준비하거나 철거한다.

**현재 상태: 구현 및 읽기 검증 단계. 실제 ON/OFF 통합 검증 전.** 관리 클러스터의 Kueue 및 워커 배포 절차가 아직 없으므로 기본 설정으로 ON/OFF를 실행하면 변경 전에 중단한다. 미완성 상태에서 Terraform만 실행하고 학습 준비 완료로 표시하지 않는다.

## 범위

현재 사용자 결정: **학습 GPU 최대 2장, 예비 GPU 0장**. Karpenter 상한은 기존 2장 유지. `config.example.json`의 `spareEnabled=false`와 `workerGpuQuotas={train-cq:2,recovery-cq:0}`는 스크립트의 기대/검증값이며 Kubernetes 큐를 직접 변경하지 않는다. 실제 큐 quota와 placeholder replicas=0은 담당자의 Gitops EKS overlay에 반영해야 한다. 예비 모드가 꺼져 있으면 ON은 예비 Pod를 기다리지 않으며, OFF도 예비 quiesce hook을 요구하지 않는다. 기존 예비 Deployment가 replicas>0이면 중단한다.

| 명령 | 동작 |
| --- | --- |
| `status` | AWS 계정, EKS 상태, CPU 희망 수, GPU EC2 수, 관리 클러스터의 작업 기록/잠금 조회 |
| `on` | eks-a 펜싱 → network plan 검증/적용 → 주 pfSense VPN 갱신 → 양쪽 터널/BGP 확인 → Karpenter·NVIDIA·스케줄링 복원 → MultiKueue와 relocator 자격 증명 교체 → Active 확인 → lifecycle 소유 펜싱 해제 |
| `off` | eks-a 실행/지명/예약/재배치 확인 → 펜싱 및 디스패처 반영 확인 → 예비 Pod/Argo 중지 → GPU NodePool 제거 및 NodeClaim/실제 EC2 종료 확인 → AWS VPN 비활성화 → network destroy plan 적용. eks-a 펜싱 유지 |

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
| `workerBootstrapScript` | master1에 있는 실행 가능한 파일의 절대 경로. EKS에 Kueue·JobSet·워커 큐/리소스 설정을 복원하는, 버전 관리된 멱등 스크립트 |
| `dispatcherBarrierScript` | eks-a 펜싱이 모든 디스패처의 진행 중 루프에 반영됐음을 확인하는 담당자 제공 절차. 단순 sleep/고정 ACK로 대체 금지 |
| `workerQuiesceScript` | 추후 spareEnabled=true일 때만 필요한 Git replicas=0 커밋 → Argo sync → 예비 Pod 0개 확인 절차. 현재 예비 0 모드에서는 불필요. 직접 kubectl scale 사용 금지 |
| `relocatorSecretNamespace` / `relocatorSecretContractConfirmed` | 담당자 최종 확인: kueue-system / true. 기존 config.local.json이 platform이면 함께 수정 필요 |
| `workerDeployments` | 복원 후 확인할 `namespace/deployment` 목록. Kueue·JobSet 컨트롤러 포함 |
| `workerClusterQueues`, `workerLocalQueues` | train-cq/recovery-cq 및 training의 queue-heavy/light/recovery. 각각 `Active=True` 확인 후 펜싱 해제 |

bootstrap/quiesce 스크립트에는 일시적인 워커 `KUBECONFIG`와 `EKS_CONTEXT`를 제공한다. quiesce에는 `WORKER_ALIAS`도 제공하며 JSON `{"worker":"eks-a","placeholderQuiesced":true}`로 완료를 반환한다. 반드시 지정 워커만 사용하고 관리 클러스터 기본 kubeconfig를 수정하지 않는다. 자격 증명을 출력/보관하지 않는다. 스크립트 제한 10분, 각 Helm 대기 제한 8분. 실패 시 펜싱 유지 후 원인 해결/재실행.

barrier에는 관리 `KUBECONFIG`, `KUBE_CONTEXT`, `WORKER_ALIAS`, `FENCE_TOKEN`을 제공한다. **펜싱 반영 및 이전 루프 종료를 실제 확인한 뒤** JSON `{"worker":"eks-a","fenceToken":"환경 변수의 FENCE_TOKEN 값","inFlightDrained":true}`로 응답한다. 이것은 신규 연동 계약이며 현재 K8s 코드에 ACK 구현은 없다. 절차가 없으면 사전 중단한다.

담당자 후속 답변: 임시 수동 절차는 펜싱 → 30초 대기 → 작업/지명/예약/재배치 재검사. 영구 방식은 디스패처가 펜싱을 본 루프를 완료한 뒤 `devoops/fenced-ack=<시각>` 기록 예정. 현재 자동 스크립트에 30초를 ACK로 간주하는 우회는 넣지 않았다. ACK가 구현되면 해당 펜싱 이후의 새 ACK인지 확인하는 adapter를 연결한다. 이전 실행의 ACK 재사용과 장비 시계 차이를 피하려면 fence token도 함께 확인하는 방식 권장.

관리 클러스터에는 `MultiKueueCluster/eks-a`가 있어야 한다. v0.20의 `spec.clusterSource.kubeConfig`(이전 spec.kubeConfig도 지원)가 `locationType: Secret`, `location: eks-a-kubeconfig`여야 한다. MultiKueue 토큰은 기존 `ansible/roles/multikueue-remote/files/rbac.yaml`, relocator 토큰은 K8s 저장소 `scheduling/controllers/deploy/worker/relocator-rbac.yaml`을 따른다. MultiKueue/dispatcher에는 nodes·pods 읽기만 추가하며 노드 수정은 relocator에 분리한다. 각 토큰으로 실제 API 조회 성공 후 관리 Secret 두 개를 교체한다.

**동적 디스패치:** 관리 ClusterQueue의 stopPolicy는 변경하지 않는다. eks-a의 `devoops/fenced=true`만 사용한다. 작업은 공용 큐에 남고 다른 워커가 있으면 그쪽으로 배정 가능하다. Argo와 복구 컨트롤러가 lifecycle 펜싱/소유권 어노테이션을 덮어쓰지 않는 계약이 필요하며, 기존 외부 펜싱은 임의 해제하지 않는다. [담당자 답변과 연동 미확정 항목](scheduling-contract.md) 참고.

```powershell
# 읽기 사전검증. 준비값이 없으면 오류로 중단, 변경 없음.
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/infra/infra.ps1 on -WhatIf

# 준비/통합 검증이 끝난 뒤 수동 실행. plan과 apply 출력은 같은 창에 표시.
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/infra/infra.ps1 on
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/infra/infra.ps1 off
```

실행 계정 `354363695096`, 리전 `us-east-2`, 대상 `devoops-prod-eks-a`, S3 backend 키 `prod/network/terraform.tfstate`를 검증한다. ON에서 리소스 교체/삭제가 필요하면 중단하고 별도로 plan을 검토한다. 일반 콘솔 변경으로 CPU 노드를 0대로 줄였더라도 ON apply는 코드의 희망 수로 복구할 수 있다.

## 안전한 종료와 실패 복구

- 관리 training Workload의 status.clusterName, status.nominatedClusterNames, devoops/reserved-cluster 및 진행 중 RelocationRequest의 대상/원본/후보 확인. eks-a 관련 항목이 있으면 OFF 거부. 재배치 대상이 미정이면 안전하게 중단.
- 워커의 실행 중 Job/JobSet, 학습 namespace의 미완료 Pod, 다른 namespace의 GPU 요청 Pod가 있으면 중단. PVC 또는 LoadBalancer Service/Ingress가 있으면 보관/정리 절차를 먼저 마련하도록 중단.
- GPU 노드의 finalizer는 강제 삭제하지 않는다. GPU 정리나 실제 EC2 종료 확인에 실패하면 CPU/Karpenter/EKS를 유지.
- 인프라 변경이 시작된 뒤 실패하면 eks-a 펜싱 유지. `status` 확인 후 원인을 해결하고 재실행. 자동 destroy 롤백 없음.
- 관리 클러스터 `kube-system/devoops-eks-a-lifecycle` ConfigMap에 잠금과 펜싱 토큰/이전 라벨/단계 보관. 동시 실행 차단. 비정상 PC 종료 후 자동 잠금 탈취 없음. **다른 실행이 없음을 확인한 뒤** data.owner만 복구. 기록 삭제 또는 외부 펜싱 강제 해제 금지. 이전 queuePolicies 기록이 남으면 공용 큐 복구를 먼저 검토하고 신규 방식으로 이관.
- EKS가 수동으로 사라졌는데 정상 GPU 정리 기록이 없으면 OFF 차단. EC2·네트워크 잔여 자원과 state를 따로 확인해야 한다.
- 운영자가 워커에 직접 제출하거나 별도 도구가 펜싱을 우회하면 이 스크립트만으로 경쟁을 방지할 수 없다. 실행 중 직접 제출/펜싱 수정 금지 필요.

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
