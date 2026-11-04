# 단일 etcd 장애 HA

control-plane VM 3대마다 host etcd를 두고, 모든 API 서버가 endpoint 3개를 사용합니다. 한 멤버가 중단돼도 정상 두 멤버가 통신하고 경보 등으로 처리가 제한되지 않았다면 etcd 클라이언트가 나머지 endpoint를 이용합니다. VM·데이터를 다른 control-plane으로 옮기는 작업이 아닙니다. API 서버가 정상이면 VIP 담당을 바꿀 필요도 없습니다. VIP 담당 노드 자체 장애는 kube-vip 리더 선출이 별도로 처리합니다.

시작 시 데이터 일관성 검사를 명시적으로 켭니다. 손상이 검출돼 시작을 거부한 한 멤버를 억지로 다시 시작하지 않습니다. 다른 두 멤버가 정상이면 단일 중단 HA 경로를 이용할 수 있습니다.

실행 중 CORRUPT 경보는 쓰기를 막을 수 있어 endpoint 전환만으로 모든 손상을 해결하지 못합니다. 멤버 제거·재가입, 경보 해제, 데이터 삭제·스냅샷 복원은 자동 수행하지 않습니다. 정족수 상실도 자동 복원 범위에서 제외합니다.

## 코드

- inventory/onprem/group_vars/k8s_cluster/ha.yml: endpoint 3개·host etcd·시작 시 손상 검사·VIP 리더 선출 명시.
- roles/topology-preflight: 3멤버 설정 사전 확인.
- playbooks/k8s/verify-etcd-ha.yml: 실제 API manifest의 endpoint 3개, 각 endpoint health·경보를 읽기 전용 검사.
- scripts/run-cluster.sh: Kubespray 적용 후 위 검사를 실행. 설정 반영은 기존 Kubespray 경로 사용.

DEGRADED_ONE_MEMBER는 정상 두 멤버로 운영하는 상태이며 세 멤버 복구 완료가 아닙니다. CORRUPTION_OR_ALARM_REVIEW·QUORUM_NOT_CONFIRMED는 검사 실패로 처리하며 데이터·멤버 구성을 변경하지 않습니다.

```bash
cd gpu-iac/ansible
# 기존 VM 설정 반영: 정상 Kubespray 적용 절차 사용
./scripts/run-cluster.sh
# 적용 환경을 읽기 전용 검사
.venv/bin/ansible-playbook -i inventory/onprem/hosts.yaml playbooks/k8s/verify-etcd-ha.yml --become
```

실제 단일 멤버 중단·API 쓰기 유지·VIP 전환 시험은 아직 하지 않았습니다. endpoint health·경보 검사는 현재 상태 확인이며 데이터 전체의 무결성을 증명하지 않습니다. 테스트 환경에서 단일 멤버 중단 후 API 읽기·쓰기를 별도 확인해야 합니다.
