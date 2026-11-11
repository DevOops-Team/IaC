# EKS 관리형 GPU 노드 — 코드 변경, 적용 전

기준 2026-11-11 사용자 결정. 쉘/ON-OFF 자동화 작업은 중단하고 Terraform부터 변경. 실제 apply·Helm 삭제·Kubernetes 변경은 실행하지 않는다. 이어질 2번 이후 요구사항은 아직 별도 논의 대상이다.

## 현재 테스트와 최종 목표

환경 이름은 prod를 유지하며 `deployment_profile`만 선택한다. 비용이 큰 최종 구성을 기본으로 만들지 않도록 기본값은 test다.

| 프로필 | EKS | 노드 AZ | CPU 온디맨드 | GPU Spot 학습 | GPU Spot 예비 | Service CIDR |
| --- | --- | --- | --- | --- | --- | --- |
| test | eks-a | us-east-2a | t3.large 1 | 2 | 0 | 10.100.0.0/16 |
| test | eks-b | us-east-2b | t3.large 1 | 0 | 0 | 10.101.0.0/16 |
| full | eks-a | us-east-2a | t3.large 1 | 4 | 1 | 10.100.0.0/16 |
| full | eks-b | us-east-2b | t3.large 1 | 4 | 1 | 10.101.0.0/16 |
| full | eks-c | us-east-2c | t3.large 1 | 4 | 1 | 10.102.0.0/16 |

- EKS 제어부의 private subnet은 기존 여러 AZ 유지. 위 AZ는 CPU/GPU 워커 그룹의 배치다. 동일 VPC·기존 VPN/NAT/Gateway Endpoint를 공유한다.
- EKS A의 module.eks_a 주소를 유지해 단순 코드 정리로 기존 A를 재생성하지 않게 했다. B는 module.eks_b, C는 full일 때만 module.eks_c[0].
- CPU는 시스템 Pod용이며 Karpenter Pod는 설치하지 않는다. GPU 없는 test B는 요청만으로 GPU 노드를 생성하지 않는다.
- GPU를 0대로 설정한 그룹은 생성하지 않는다. 활성 그룹은 min=desired=max. full 목표는 15노드/15GPU지만 Spot 회수·용량 부족·교체 중 실제 정상 노드 수를 항상 보장하지 않는다. ASG의 Spot Capacity Rebalancing도 일시적 수량 변동을 일으킬 수 있다.
- 관리형 그룹 자체가 수량을 유지하므로 노드 유지용 placeholder Pod는 불필요. 예비 taint/복구 작업 toleration은 유지한다. GPU를 쥔 placeholder를 기존처럼 배포하면 GPU 1장을 불필요하게 점유하므로 담당자 overlay에서 제거/비활성화해야 한다.

## GPU 그룹의 설정 위치

`environments/prod/network/eks.tf`에서 프로필별 수량과 AZ, 허용 유형을 정한다. `modules/eks/gpu-nodes.tf`가 그룹별 IAM·Launch Template·Managed Node Group을 만든다.

- 허용 유형: g4dn.xlarge(4vCPU/16GiB/T4 1장), g4dn.2xlarge(8vCPU/32GiB/T4 1장). 어느 유형이 선택돼도 인스턴스 1대=GPU 1장. CPU/RAM은 달라질 수 있으므로 JobSet 요청량을 작은 유형에서도 실행 가능한지 검토해야 한다.
- 모두 SPOT. EKS 관리형 그룹/ASG의 할당 전략이 지정 AZ와 유형 범위에서 공급한다. 온디맨드 자동 fallback 없음. 유형 순서를 xlarge 우선 보장으로 해석하지 않는다.
- 기본 NVIDIA AMI: AL2023_x86_64_NVIDIA, EKS1.35, release_version=1.35.9-20261107. us-east-2 AWS public SSM에서 읽기 확인한 값으로 고정. 기존 Karpenter custom AMI ID를 그대로 이식하지 않는다.
- GPU root EBS20GiB(gp3·암호화·노드 종료 시 삭제)는 이전 NodePool 크기 유지. 학습 데이터/체크포인트는 S3. IMDSv2 필수.
- 양쪽 그룹 `devoops/gpu=true`, `devoops/node-role=training|spare`, GPU taint `nvidia.com/gpu=true:NoSchedule`. 예비만 추가 라벨/taint `devoops/spare=true:NoSchedule`.
- EC2 인스턴스 태그: EKSCluster(실제 클러스터명), NodeRole(training/spare), Project, Environment, ManagedBy. Karpenter nodepool 태그는 더 이상 기준이 아님. 복구 담당자의 EC2 조회/종료 필터도 이 태그에 맞춰 별도 검토해야 한다.
- 노드 역할은 AmazonEKSWorkerNodePolicy·AmazonEC2ContainerRegistryPullOnly만. CNI와 trainer의 Pod Identity는 별도 유지. 온프레 DescribeCluster IAM은 a/b/c 세 ARN에만 확장한다. TerminateInstances 등의 추가 권한은 이번 요청으로 임의 부여하지 않는다.
- GPU AMI update는 MINIMAL·maxUnavailable=1로 업데이트 전 증설을 줄인다. 업데이트 중 그룹의 가용 노드가 감소할 수 있다. 고정 목표는 무중단/항상 Ready 5대 보장이 아니다.

## 할당량 — 현재 배포 전 제한

읽기 조회 결과 us-east-2 All G and VT Spot Instance Requests=8 vCPU, GPU On-Demand=0. user 요청대로 모든 GPU는 Spot이며 CPU t3.large 온디맨드는 별도 일반 인스턴스 할당량 사용.

- test A의 GPU2대는 xlarge만 있으면8vCPU, 2xlarge 두 대면16vCPU 필요. 후보 두 종류를 허용하므로 현재8vCPU로는 원하는2대를 못 채울 수 있다.
- full GPU15대는 모두 xlarge여도60vCPU, 모두2xlarge면120vCPU. 리전 전체의 다른 G/VT Spot도 같은 quota를 사용한다. full은 현재 quota로 배포할 수 없다.
- Terraform plan 성공은 Spot 공급/할당량 확보나 노드 Ready의 증명이 아니다. 이번에는 quota 변경을 요청하거나 실제 인스턴스를 생성하지 않는다.

## plan 선택 (apply 없음)

기존 CMD/PowerShell의 prod/network에서:

```powershell
terraform init -backend-config="../../../backends/prod/network.s3.tfbackend"
terraform validate
# 현재 테스트용
terraform plan -var-file="terraform.local.tfvars" -var-file="topology-test.tfvars"
# 최종 규모 검토용: 실제 적용은 quota/이관/후속 요구사항 정리 뒤
terraform plan -var-file="terraform.local.tfvars" -var-file="topology-full.tfvars"
```

두 프로필은 **동일 state/동일 prod 리소스 이름**을 사용한다. 서로 독립된 환경을 동시에 만드는 용도가 아니다. full→test는 C 삭제·A 축소·예비 삭제를 포함할 수 있다. 저장 plan의 적용은 선택한 프로필을 정확히 검토한 뒤 별도 실행한다.

## 기존 Karpenter에서 이관 전 점검

1. 실행 중 학습/예약/재배치가 없는지, 기존 NodePool·NodeClaim·EC2 목록과 데이터 보존 위치 확인.
2. 신규 GPU 그룹 준비와 NVIDIA 플러그인의 두 taint 허용 확인. Kueue·JobSet Gitops overlay는 Managed Node Group 라벨을 사용하도록 담당자와 조정. test는 train quota2/예비0, full은 train4/예비1.
3. 기존 GPU를 옮기거나 비운 뒤 **Karpenter가 살아 있는 동안** 기존 NodePool/NodeClaim과 실제 EC2 정리 확인. finalizer 강제 제거 금지. 기존 GPU가 새 노드그룹에 자동 편입되지 않는다.
4. 기존 Karpenter Helm/controller와 Pod Identity 참조를 정리할 순서 확인 후 Terraform 삭제 계획 검토. 제거된 module.karpenter_a의 IAM·SQS·EventBridge는 state에 있으면 destroy로 표시된다. IAM부터 없애면 기존 GPU 정리가 막힐 수 있다.
5. 관리형 Spot 그룹의 AWS Capacity Rebalancing과 학습 앱의 회수 예고/체크포인트/relocator 처리 연결을 쿠버·복구 담당자와 확인. 기존 Karpenter SQS 소비 경로가 남아 있다고 가정하지 않는다.

위는 이관 전 점검 기록이며 자동 실행 절차가 아니다. 사용자 요청으로 scripts/infra는 수정/실행하지 않았다. 예전 스크립트는 Karpenter output/NodePool을 참조하므로 현재 코드에 사용하지 않는다.

## 검증

2026-11-11 실제 AWS state와 비교한 plan(적용 없음):

| 루트/프로필 | 생성 | 변경 | 삭제 |
| --- | --- | --- | --- |
| network/test | 31 | 1 | 20 |
| network/full | 67 | 1 | 20 |
| identity | 0 | 2 | 0 |

network의 삭제20개는 기존 module.karpenter_a의 IAM·Pod Identity·Access Entry·SQS·EventBridge 자원. 기존 EKS A 재생성 없음. 변경1개는 콘솔에서0대로 줄인 CPU 그룹을 코드의1대로 복원하는 계획. identity의2개는 relocator/MultiKueue DescribeCluster 리소스를 A/B/C로 확장하는 인라인 정책. plan은 저장/적용하지 않았으며 후속 요구사항 확정 뒤 새로 검토해야 한다.

`terraform init -backend=false`, fmt/validate, AWS를 mock한 `terraform test`로 test/full 두 프로필의 수량·Spot·허용유형·AZ·예비 분리·Service CIDR·NVIDIA toleration을 검사한다. mock test는 AWS 리소스를 생성하지 않는다. 실제 GPU Ready·애플리케이션 장애복구 E2E는 배포 후 별도 검증 대상.

공식 근거: [EKS 관리형 노드 그룹](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html), [GPU 노드 그룹](https://docs.aws.amazon.com/eks/latest/userguide/ml-node-groups.html), [업데이트 동작](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-update-behavior.html).
