# 팀 문서와 코드의 접속·실행 계약

대조일: 2026-11-09. 아래는 현재 로컬 코드의 기준이며 실제 설치·접속 성공을 뜻하지 않는다. 문서가 다른 이름을 사용하면 합의 없이 두 경로를 동시에 만들지 않는다.

| 대상 | 현재 기준 | 근거·상태 |
|---|---|---|
| 복구 컨트롤러 | namespace `platform`, Deployment·ServiceAccount `recovery-controller` | 스케줄링 문서의 `platform/recovery-controller`와 K8s 매니페스트 일치. 과거 IAM 요청의 `recovery` namespace는 현재 코드에 적용하지 않음. IAM 인증 주체와의 최종 연결은 인프라 담당과 확인 |
| 재배치 요청 | 관리 클러스터 `training`의 RelocationRequest | 스케줄링 문서, 복구 규약 |
| EKS 학습 계정 | `training/trainer` | 체크포인트 규약 §13. 온프레 controller의 AWS 인증과 별개 |
| 관리 API | `https://172.30.0.120:6443` | 인프라 설정값 v4: 사용 중. kubeconfig context 이름·NIC는 실제 환경 입력 |
| VM SSH | master1~3 `.11/.12/.13`, worker1~3 `.21/.22/.23` | subnet 172.30.0.0/24. 로그인 이름=VM 이름 |
| 물리 호스트 | master1/worker1=devoops, master2/worker2=pve1, master3/worker3=pve2 | 인프라 v4. 이전 server/laptop1/laptop2 표시를 교체 |
| Kafka 목표 접속 목록 | `172.30.0.40:9092,172.30.0.41:9092,172.30.0.42:9092` | VM 주소 확인, KRaft 3대 전환 중. 설치·advertised.listeners·인증·ACL 확인 후 사용 |
| 모니터링 | API `.30:6443`, 서비스 VIP `.35` | 예약 상태. Alertmanager 실제 URL/포트는 아직 배포값을 확인해야 함 |
| Ansible | Kubernetes 밖 개인 PC에서 수동 실행 | 채택된 ADR-11. 전용 VM·상시 점검 timer 없음 |

Kubernetes ServiceAccount와 Ubuntu SSH 계정, AWS IAM role은 서로 다른 계정이다. `platform/recovery-controller`를 사용한다고 AWS 인증이 자동으로 생기지 않는다. Roles Anywhere 등 온프레 인증·권한 연결은 담당 구성과 맞춘다. EKS/Argo/MultiKueue 실제 API URL은 각 kubeconfig·EKS 입력에 두며 임의 DNS 이름으로 치환하지 않는다.

## 근거

- [ADR-11, 채택](https://devoops-team.atlassian.net/wiki/spaces/GPUF/pages/11730951)
- [온프레 인프라 설정값 v4](https://devoops-team.atlassian.net/wiki/spaces/GPUF/pages/9732117)
- [평소 학습·장애복구 스케줄링 방식](https://devoops-team.atlassian.net/wiki/spaces/GPUF/pages/8617985)
- [체크포인트 규약 §13](https://devoops-team.atlassian.net/wiki/spaces/GPUF/pages/9699330)
- [데이터 파트 설계 — Kafka 3대 전환](https://devoops-team.atlassian.net/wiki/spaces/GPUF/pages/2916376)

네트워크 아키텍처 문서는 Kafka 단일 주소와 이전 Tunnel 설명이 남아 있어, VM 주소는 더 최신 인프라 v4, Kafka 목표 목록은 데이터 파트 문서를 우선했다. 공인 IP·pfSense WAN·EKS endpoint·IAM role·Kafka 인증은 미확정값을 만들지 않는다. Cloudflare/pfSense의 로컬 변경과 실제 전환은 EDGE.md에서 구분한다.
