# gpu-iac — Kubernetes 실행 기반

이 폴더는 Terraform 영역과 Ansible/Kubespray 실행 기반을 관리합니다. 실제 서버 적용·GitHub push는 수행하지 않았습니다.

```text
gpu-iac/
├─ terraform/             # VM/AWS 자원 담당 코드 영역 (현재 비어 있음)
├─ ansible/
│  ├─ inventory/onprem/   # Kubernetes VM 6대·HA·MAP 설정
│  ├─ playbooks/
│  │  ├─ infra/           # VM 준비·설치 전 검사
│  │  ├─ k8s/             # 관리 API MAP 확인
│  │  ├─ bootstrap/       # Argo CD 최초 설치·Secret·root 등록
│  │  ├─ network/         # 외부 Cloudflare Tunnel·DNS API
│  │  └─ site.yml         # 클러스터 설치 후 bootstrap 실행
│  └─ roles/
└─ .vscode/               # 이 폴더용 설정·구문 검사 task
```

앱 Deployment·Service·RBAC, Traefik·cert-manager values, frontend Ingress·웹 인증서, cloudflared Pod, EKS 큐·MultiKueue 연결 객체는 형제 폴더 gpu-k8s로 이동했습니다. 이 저장소에서 해당 리소스를 반복 적용하지 않습니다.

Cloudflare의 실제 계정 리소스 생성과 Secret 등록은 bootstrap이며, cloudflared의 원하는 Pod 상태는 GitOps가 관리합니다. Kubernetes VM·API VIP·CoreDNS·MAP는 Kubespray가 관리합니다. Kueue·JobSet 컨트롤러는 스케줄링 파트 담당입니다.

실행 순서는 [ansible/PROJECT.md](ansible/PROJECT.md)를 확인합니다. 두 폴더를 각각 VS Code로 열어 사용할 수 있고, *.code-workspace는 각 폴더만 포함합니다.

## 장애 감지·서비스 복구

`ansible/playbooks/recovery/`, `ansible/scripts/recovery/`에 진단·분류·제한적 복구와 메인 서버 전용 Ubuntu VM의 실행기 timer를 추가했습니다. 기본은 관찰 전용이며 설치/부트스트랩 site.yml과 분리합니다. [RECOVERY.md](ansible/RECOVERY.md)를 확인합니다.
