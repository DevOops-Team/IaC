# 모니터링 Kubernetes 클러스터

| VM | Proxmox | LAN |
| --- | --- | --- |
| monitoring1 | pve3 | 172.30.0.31 |
| monitoring2 | pve3 | 172.30.0.32 |
| monitoring3 | pve1 | 172.30.0.33 |

세 VM에 control-plane, etcd, 워커 역할 배치. pve3 물리 호스트 장애 시 etcd 멤버 두 대가 동시에 내려가 정족수 상실.

- API VIP는 `172.30.0.30:6443`. 세 노드의 `eth0`에서 kube-vip ARP로 광고.
- 서비스 VIP는 `172.30.0.35`. 담당자가 각 `type: LoadBalancer` Service에 `kube-vip.io/loadbalancerIPs: "172.30.0.35"` annotation과 `externalTrafficPolicy: Cluster`를 설정하고 서로 다른 서비스 포트 사용.
- LAN DHCP 활성화 시 두 VIP를 동적 할당 범위에서 제외.
- Service CIDR은 `10.234.0.0/18`, Pod CIDR은 `10.234.64.0/18`.

실행기에서 세 VM의 LAN IP로 SSH 및 sudo가 가능한지 확인. 관리 클러스터 전용 `run-cluster.sh`는 `inventory/onprem`을 사용하므로 모니터링 클러스터는 아래처럼 별도 inventory로 실행.

```bash
cd ansible
./scripts/setup-kubespray.sh
root="$(pwd)"
cd .vendor/kubespray
# Kubespray ansible.cfg는 UserKnownHostsFile=/dev/null이라 호스트 키 검증을 켜려면 ssh_args를 덮어쓴다 (run-cluster.sh와 동일).
export ANSIBLE_HOST_KEY_CHECKING=True
export ANSIBLE_SSH_ARGS='-o ControlMaster=auto -o ControlPersist=60s'
"$root/.venv/bin/ansible-inventory" -i "$root/inventory/monitoring/hosts.yaml" --graph
"$root/.venv/bin/ansible-playbook" -i "$root/inventory/monitoring/hosts.yaml" cluster.yml --syntax-check
"$root/.venv/bin/ansible-playbook" -i "$root/inventory/monitoring/hosts.yaml" cluster.yml --become --ask-become-pass
```

kubeconfig는 `"$root/.venv/bin/ansible-playbook" -i "$root/inventory/monitoring/hosts.yaml" "$root/playbooks/k8s/admin-kubeconfig.yml" --become --ask-become-pass`로 세 노드 계정에 배포하고, 로컬은 `inventory/monitoring/artifacts/admin.conf`(gitignore)를 쓴다.

배포 후 API VIP로 `kubectl get nodes` 실행 확인. 서비스 배포 후 `EXTERNAL-IP` 및 각 포트 연결 확인.
