# 인증서 자동 갱신과 반영

코드 설정이며 서버 적용·실제 발급 시험은 하지 않았습니다. EKS 내부 인증서는 AWS 관리 영역이며 이 설정은 온프레미스에만 적용됩니다.

## 1. API 등 kubeadm 관리 인증서

inventory에서 auto_renew_certificates=true. Kubespray v2.32의 갱신 script/timer를 사용합니다. script는 만료가 다음 주기+여유 기간에 가까워졌을 때 kubeadm certs renew all을 실행하고 kubeadm 관리 control-plane 컨테이너를 재시작하여 반영하며 /root/.kube/config도 갱신합니다.

master1 첫 월요일, master2 첫 화요일, master3 첫 수요일, 각 03:00 UTC(한국 12:00)에 실행합니다. 프로젝트 drop-in은 Persistent=false로 재부팅 후 밀린 세 노드의 동시 실행을 막고 랜덤 지연을 제거합니다. 각 노드에서 API readyz와 다른 두 control-plane Node Ready를 확인한 후 실행하며 로컬 flock과 20분 제한을 사용합니다. 이는 직접 etcd 멤버 health 검사나 클러스터 전역 잠금을 대체하지 않습니다. Node Ready만으로 모든 etcd 상태를 증명할 수는 없습니다.

Kubespray 설치 뒤 scripts/run-cluster.sh가 configure-certificates.yml을 이어서 실행합니다. 이미 설치한 환경은 먼저 해당 inventory로 Kubespray를 적용해 rotateCertificates와 갱신 script/timer를 설치한 뒤 아래 통합 플레이북을 실행합니다.

```bash
cd gpu-iac/ansible
.venv/bin/ansible-playbook -i inventory/onprem/hosts.yaml playbooks/k8s/configure-certificates.yml --become
```

프로젝트 wrapper는 upstream script를 수정하지 않습니다. Kubespray만 따로 실행하거나 인증서 태그로 제한해 적용했다면 프로젝트 플레이북도 다시 실행·확인하세요. --tags/--limit은 필요한 역할을 생략할 수 있어 부분 적용 후에는 전체 검증이 필요합니다.

CA 자체·Kubespray의 host etcd 인증서는 kubeadm 갱신 범위가 아닙니다. etcd는 별도 인증서 관리 절차가 필요하며 이 코드에서 회전하지 않습니다. 외부 PC/Ansible 실행기/Argo에 복사된 client kubeconfig도 자동 갱신되지 않습니다. 단기 인증·별도 자격증명 관리 또는 갱신된 admin.conf의 보안 재배포가 필요합니다. 이미 만료돼 API 인증이 불가능하면 wrapper는 중단하므로 수동 복구 절차를 사용합니다.

## 2. kubelet API 접속 인증서

kubelet_rotate_certificates=true를 명시합니다. kubelet이 만료 전 CSR을 제출하고 정상 RBAC·승인·서명 경로가 있으면 발급된 새 client 인증서를 자체 반영합니다. 매번 kubelet을 재시작할 필요는 없습니다. configure-certificates.yml은 6개 VM의 rotateCertificates=true를 확인합니다.

kubelet HTTPS serving 인증서는 별개입니다. 모든 CSR 자동 승인은 하지 않으며 kubelet_rotate_server_certificates=false를 유지합니다. 별도 신원 검증 approver 없이 serving rotation을 켜지 않습니다.

## 3. 웹 HTTPS

gpu-k8s/onprem/platform/web/resources.yaml의 Certificate는 90일 요청·만료 30일 전 갱신·개인키 Always rotation을 설정했습니다. 실제 유효기간은 발급기관이 결정합니다. cert-manager → platform/frontend-tls Secret 갱신 → Kubernetes Ingress provider를 켠 Traefik이 Secret watch로 새 TLS 설정 반영. 별도 frontend/backend Pod 재시작은 필요 없습니다. Cloudflare edge 인증서는 Cloudflare 관리 영역입니다.

Cloudflare DNS API 토큰·실제 ACME email·DNS 권한·외부 ACME 접근·실행 중인 cert-manager/Traefik이 필요합니다. 아직 Argo 적용하지 않았으므로 파일 수정만으로 발급되지 않습니다.

## 확인

```bash
# 각 master VM
systemctl status k8s-certs-renew.timer
systemctl cat k8s-certs-renew.timer k8s-certs-renew.service
journalctl -u k8s-certs-renew.service
sudo /usr/local/bin/kubeadm certs check-expiration
# API 접근 가능한 관리 환경
kubectl --context YOUR_CONTEXT get csr
kubectl --context YOUR_CONTEXT -n platform get certificate frontend-tls -o yaml
```

웹 갱신 후에는 frontend-tls의 새 인증서 serial과 실제 Traefik TLS endpoint가 제공하는 serial을 비교해 반영을 시험합니다. Secret의 private key는 출력하지 마세요. 만료 일자·갱신 실패 알림은 모니터링 담당 연동이 필요하며 아직 Prometheus 규칙을 배포하지 않았습니다.
