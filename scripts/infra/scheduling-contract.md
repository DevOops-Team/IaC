# 스케줄링 담당자와의 lifecycle 계약

기준: 2026-11-11 사용자 전달 답변 및 K8s HEAD `f15b265d5db594340775802a2355fe4f88bec53d` 읽기 확인. 실제 설치 완료를 뜻하지 않는다.

## 확정한 동작

고정 관리 큐 없음. 디스패처가 실행 클러스터를 동적으로 선택하므로 공용 ClusterQueue를 Hold하지 않고 MultiKueueCluster/eks-a에 `devoops/fenced=true` 적용. 다른 워커가 있으면 그쪽으로 배정 가능하고, 없으면 관리 클러스터에서 대기. ON 준비 완료 후 lifecycle이 소유한 펜싱만 해제하며 재제출 불필요.

OFF 거부 조건은 관리 training namespace에서 다음 중 하나가 존재하는 경우다.

- 미완료 Workload의 `status.clusterName == eks-a`
- 미완료 Workload의 `status.nominatedClusterNames`에 eks-a 포함
- 미완료 Workload의 `devoops/reserved-cluster == eks-a`
- 처리 중 RelocationRequest가 eks-a를 원본/대상/기존 복사본 보유 클러스터로 참조. jobRef가 가리키는 JobSet의 Workload도 확인. 대상을 아직 판단할 수 없거나 향후 선택할 가능성이 있으면 보수적으로 중단

확인 → 펜싱 → 디스패처의 이전 루프 종료 확인 → 활동 재확인 → 워커 정리 순서. 담당자의 임시 수동 절차는 펜싱 후 30초 대기와 네 가지 거부 조건 재검사. 이는 루프가 오래 지연된 경우까지 완료를 보장하는 ACK와 구분한다. 자동 OFF는 ACK 구현 및 adapter 연결 전까지 중단 유지.

## ON 설치 순서

K8s 저장소 `scheduling/` 기준:

1. `kubectl apply --server-side -k kueue/worker`, kueue-system/kueue-controller-manager rollout 확인
2. `kubectl apply --server-side -k jobset/base`, jobset-system/jobset-controller-manager rollout 확인
3. `kubectl apply -k queues/worker/base`: training, train-cq/recovery-cq, queue-heavy/light/recovery
4. training/devoops-cluster-info의 CLUSTER_NAME=eks-a
5. examples/spare/placeholder.yaml: 예비 자리 표시 Deployment
6. controllers/deploy/worker/relocator-rbac.yaml: 별도 relocator ServiceAccount와 RBAC
7. 관리 Secret 두 개를 새 endpoint/CA/각각의 SA 토큰으로 교체하고 MultiKueueCluster/eks-a Active 확인

위 순서는 담당자 설명을 기록한 것이며 kind용 base를 바로 운영에 적용하는 실행 명령이 아니다. EKS overlay(`devoops/gpu=true`, waitForPodsReady 10m)가 준비돼야 workerBootstrapScript에 연결한다. Gitops eks/scheduling/overlays/eks-a가 채워지면 4~6번은 Argo가 관리할 예정. 스크립트가 동일 리소스를 다른 값으로 별도 소유하지 않는다.

ON은 ConfigMap의 클러스터 이름, 예비 Deployment 복원/rollout, 컨트롤러 rollout, 워커 큐 Active, 두 자격 증명의 API 접근 및 MultiKueue Active를 확인한 뒤 펜싱 해제. Karpenter/NVIDIA는 Terraform의 고정 버전 output을 사용한다.

## 추가 확인 중인 사항

| 항목 | 현재 발견한 상태 / 필요한 결정 |
| --- | --- |
| 펜싱 경쟁 방지 | 담당자가 `devoops/fenced-ack=<시각>` 구현 예정. fenced를 본 루프를 끝낸 뒤 ACK 기록, ACK가 펜싱 적용 시각 이후인지 확인하는 계획. 현재 ACK는 없으며 자동 OFF 미연결. 현재 fence token도 함께 대조하면 지난 실행 ACK/시계 차이 문제를 줄일 수 있음 |
| 예비 Pod 중지·복원 | 담당자가 Gitops eks-a overlay에 replicas 패치 추가 예정. OFF: Git replicas=0 커밋 → Argo sync → spare-placeholder Pod 0개 확인. ON: 기반 복원 후 Git replicas=1 커밋 → Pod Running/rollout 확인 → 펜싱 해제. kubectl scale/delete는 selfHeal이 되돌리므로 사용하지 않음. 아직 실행 가능한 hook은 미제공 |
| relocator Secret 위치 | 담당자 최종 확인은 `kueue-system/eks-a-relocator-kubeconfig`. 기존 platform 답변 정정. 설정 예시에 반영 완료. EKS overlay의 controller Role resourceNames에는 eks-a 이름을 포함해야 함 |
| GPU 라벨 | IaC의 기존 node-role.devoops.site/gpu를 담당자 기준 devoops/gpu로 변경. 코드 변경만 진행하며 기존 NodePool/노드에 실제 적용하지 않음 |
| 4+1과 할당량 | base 큐는 train 4 + recovery 1. 현재 IaC GPU NodePool은 최대 2장, 일반 NodePool 하나이며 devoops/spare=true용 별도 예비 노드 구성도 아직 없음. EKS overlay의 실험 용량/예비 전략을 맞춰야 함. 5장으로 임의 확대하지 않음 |
| dispatcher 읽기 권한 | MultiKueue 토큰으로 nodes/pods 용량을 조회하므로 해당 RBAC에 get/list 추가. patch/cordon 같은 노드 수정은 별도 relocator 토큰에만 유지 |

현재 `workerBootstrapScript`, `workerQuiesceScript`, `dispatcherBarrierScript`는 미제공이다. namespace는 확정했지만 Git 패치·Argo 동기화·ACK 절차를 실제 hook에 연결하기 전에는 AWS·쿠버 리소스 변경 전에 중단한다. 이번 변경은 코드/단위 검증이며 ON/OFF 통합 검증·실제 배포 아님. 담당자가 구현하고 알려주겠다고 한 상태이며 인프라 쪽에서 dispatcher/overlay를 대신 변경하지 않는다.

## 소스

- [디스패처](https://github.com/DevOops-Team/K8s/blob/f15b265d5db594340775802a2355fe4f88bec53d/scheduling/controllers/dispatcher.py)
- [워커 자격 증명 reader](https://github.com/DevOops-Team/K8s/blob/f15b265d5db594340775802a2355fe4f88bec53d/scheduling/controllers/kube.py)
- [RelocationRequest CRD](https://github.com/DevOops-Team/K8s/blob/f15b265d5db594340775802a2355fe4f88bec53d/scheduling/controllers/deploy/crd-relocationrequest.yaml)
- [예비 placeholder](https://github.com/DevOops-Team/K8s/blob/f15b265d5db594340775802a2355fe4f88bec53d/scheduling/examples/spare/placeholder.yaml)
