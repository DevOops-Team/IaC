# Cloudflare / GitOps 경계

외부 사용자 → Cloudflare Tunnel → cloudflared → Traefik 내부 ClusterIP:443 → frontend Service:3000입니다.
서비스 VIP는 사용하지 않으며 Kubernetes API VIP는 별도로 유지합니다. backend는 내부 ClusterIP이고 Ingress가 없습니다.

- gpu-iac: 실제 Cloudflare 계정의 원격 관리 Tunnel·호스트 경로·DNS, token Secret.
- gpu-k8s: Traefik/cert-manager Helm values, Certificate·Ingress, cloudflared Deployment/PDB.
- cert-manager: cloudflare-dns-api-token을 사용해 ACME DNS-01을 처리하고 TLS Secret을 생성·갱신.

Bootstrap config의 acme_environment=production, frontend Certificate Ready·Service endpoint 확인 후 외부 경로를 구성합니다. 기존의 관계없는 DNS는 덮어쓰지 않고 중단합니다. 내부 Origin은 https://traefik.ingress-system.svc.cluster.local:443이고 originServerName/httpHostHeader=devoops.site로 TLS를 검증합니다. noTLSVerify를 켜지 않습니다.
Cloudflare provider는 기존 다른 hostname route를 보존하고 이 도메인 경로만 갱신합니다. 코드에 token을 넣지 않고 Kubernetes Secret으로 공급합니다.
최초 구성은 PROJECT.md와 gpu-k8s/docs/bootstrap.md를 따릅니다.
