# Vault VM · Kubernetes 연결 (GPU-241)

채택 방식은 **외부 Vault VM + Raft + Shamir 수동 unseal + VSO + 정적 KV v2**다.
서비스 비밀번호를 변경하거나 운영 VM에 적용하는 PR이 아니다. 기존 서비스의 Secret 이름·key·값을 유지한다.

## 역할 분리

| 대상 | 담당 |
|---|---|
| Proxmox VM 생성·디스크·고정 IP·초기 SSH | 기존 인프라 담당/Terraform. 이 Ansible은 이미 있는 VM에 접속한다. |
| Vault 패키지·Raft 설정·TLS·systemd | `playbooks/vault/configure-vms.yml` → `roles/vault-server` |
| VSO 최초 설치 | 선택 실행 `playbooks/bootstrap/install-vso.yml`. 기본 `site.yml`에 포함하지 않는다. |
| VSO 운영 values·VaultConnection·VaultAuth·VaultStaticSecret·인증 SA/RBAC | Gitops 담당. 동일 Helm release를 Ansible과 Argo CD가 동시에 변경하지 않는다. |
| KV 값·Vault 정책/role·Kubernetes auth·수동 init/unseal·snapshot | 운영자가 Vault CLI로 수행. 토큰·unseal key·비밀번호는 Git/Ansible vars에 저장하지 않는다. |

Kubespray의 API VIP `.120:6443`, CoreDNS, MAP, Kubernetes 노드 설정은 변경하지 않는다.
Backend의 `platform/backend-db`와 Collector의 `data-system/collector-db` 참조도 그대로 둔다.
AWS Pod Identity/Roles Anywhere와 cert-manager의 인증서 발급 방식은 유지한다.

## VM 구성

| VM/SSH 계정 | 물리 호스트 | 주소 | 기본 실행 대상 |
|---|---|---|---|
| vault1 | devoops | 172.30.0.81 | `vault_servers` — 단일 서버 시작 |
| vault2 | pve2 | 172.30.0.82 | `vault_future` — 현재 실행 안 함 |
| vault3 | pve4 | 172.30.0.83 | `vault_future` — 현재 실행 안 함 |

Vault `2.2.2` / Debian package `2.2.2-1`을 고정하고 hold한다. Raft 데이터는 `/opt/vault/data`,
설정은 `/etc/vault.d/vault.hcl`, TLS는 `/etc/vault.d/tls/vault.{crt,key}`다.
관리 TLS 주소는 `https://172.30.0.81:8200`, 노드 통신은 `8201`이다.
첫 구축의 자체 서명 인증서는 365일이며 SAN에 노드 이름·노드 IP·127.0.0.1을 넣는다.
만료 7일 미만이면 실패하며 자동 갱신/교체하지 않는다. 발급/교체는 별도 유지보수로 진행한다.

## 1. 검사와 VM 구성

개인 PC 또는 Ansible 실행 환경에서 `cd ansible` 후 실행한다. Ansible core 2.20, Ubuntu VM,
SSH/sudo 권한이 필요하다. 비밀번호 방식이면 `--ask-pass --ask-become-pass`를 추가한다.
Vault 전용 VM의 swap은 먼저 운영자가 재부팅 후에도 꺼지도록 준비한다. role은 swap을 임의로 변경하지 않는다.

```bash
ansible-inventory -i inventory/vault/hosts.yaml --graph
ansible-playbook -i inventory/vault/hosts.yaml playbooks/vault/configure-vms.yml --list-hosts
ansible-playbook -i inventory/vault/hosts.yaml playbooks/vault/configure-vms.yml --syntax-check
ansible-playbook -i inventory/vault/hosts.yaml playbooks/vault/configure-vms.yml \
  --check --diff -e vault_configure_confirmed=true

# 새 VM 최초 설치 (위 점검 뒤 명시적으로 실행)
ansible-playbook -i inventory/vault/hosts.yaml playbooks/vault/configure-vms.yml \
  -e vault_configure_confirmed=true
```

기존 수동 설치 `.81`에서는 먼저 Raft snapshot을 VM 밖에 보관하고 실행 중 설정을 비교한다.
실행 중 config/systemd 차이가 있으면 쓰기 전에 중단한다. 적용 시 서비스 재시작과 수동 unseal이
필요할 수 있으므로 중단 시간을 잡고 `-e vault_restart_confirmed=true --limit vault1`을 명시한다.
패키지 버전이 다르거나 TLS 한쪽 파일만 있으면 자동 복구/업그레이드하지 않고 중단한다.
기존 인증서·개인키는 재발급하지 않고 SAN·만료·키 일치 여부를 검증한다.
새 VM `--check`는 파일/계정이 아직 없으므로 실제 설치·기동 성공을 보장하지 않는다.

role은 **init·unseal·login·KV write·auth 설정·audit enable·Raft join을 실행하지 않는다.**
기존 Raft 데이터를 삭제하거나 재귀 chown하지 않는다. health 응답 501(미초기화)·503(sealed)은 설치 실패로 처리하지 않는다.

## 2. 최초 초기화와 재시작

Vault VM의 SSH 사용자 홈에 공개 인증서 `~/vault-ca.crt`를 복사한다. 개인키 접근 권한은 풀지 않는다.

```bash
export VAULT_ADDR=https://172.30.0.81:8200
export VAULT_CACERT="$HOME/vault-ca.crt"
vault status

# Initialized=false인 신규 서버에 한 번만 실행한다.
vault operator init -key-shares=5 -key-threshold=3

# 서로 다른 키를 프롬프트에 하나씩 입력한다. 재시작 후에도 필요하다.
vault operator unseal
vault operator unseal
vault operator unseal
vault login

# 최초 한 번. audit 경로 생성만으로 감사 로그가 켜지는 것은 아니다.
vault audit enable file file_path=/var/log/vault/audit.log
```

출력되는 root token과 unseal key는 VM 밖의 승인된 보관소에 보관한다. root token은 초기 설정에만 쓰고
별도 운영자 인증·정책을 검증한 뒤 폐기한다. 감사 로그 용량/rotation 담당도 정한다.
snapshot은 토큰을 인자에 넣지 않고 로그인된 세션에서 `vault operator raft snapshot save <파일>`로 만든다.
snapshot·unseal 수단·TLS 키의 안전한 외부 보관과 복원 시험은 별도 운영 절차다.

## 3. VSO 최초 설치와 GitOps 인계

관리 클러스터 API는 `https://172.30.0.120:6443`이다. VSO Pod → Vault `.81:8200`,
Vault VM → 관리 API `.120:6443` 경로가 모두 필요하다. 방화벽을 전체 공개하지 않는다.
`8201`은 향후 Vault 노드 사이에만 허용한다. 이 PR은 UFW/pfSense 규칙을 임의로 바꾸지 않는다.

```bash
cp bootstrap.example.yml bootstrap.local.yml
# manager_context를 실제 관리 context로 설정한다.
ansible-playbook playbooks/bootstrap/install-vso.yml \
  -e @bootstrap.local.yml -e vso_bootstrap_confirmed=true
```

VSO chart `1.6.0`, release `vault-secrets-operator`, namespace `vault-secrets-operator-system`.
같은 버전의 기존 Helm release는 재설치/값 초기화하지 않고 준비 상태만 확인한다.
버전 변경은 `vso_allow_upgrade=true`를 별도로 지정해야 한다.
기존 release가 없는 경우라도 수동/Argo 배포와 중복되지 않는지 먼저 확인한다.
Argo CD로 인계한 뒤에는 이 bootstrap 플레이북을 운영 upgrade 용도로 반복 실행하지 않는다.

### 찬경님 검토/인계 항목

현재 확인한 Gitops main에는 VSO Application/운영 리소스가 없다. 다음을 Gitops에서 선언해야 재구축이 완성된다.

- VSO namespace·고정 Helm chart·values·Argo Application과 허용 AppProject 범위. 수동 Helm release 인계 방식 결정.
- namespace별 `VaultConnection`과 공개 CA Secret(`ca.crt`). 자체 서명 인증서도 TLS 검증을 끄지 않는다.
- 서비스별 동기화 전용 SA와 `VaultAuth`. 외부 Vault Kubernetes auth에는 API 주소·공개 CA를 등록한다.
  현재 client JWT reviewer 방식은 해당 SA에 `authentication.k8s.io/tokenreviews:create`만 별도 부여한다.
  JWT audience는 VSO 발급 요청과 Kubernetes TokenReview 양쪽이 맞는지 확인한 후 함께 설정한다.
- `VaultStaticSecret`: 기존 대상이면 `destination.create: false`, `transformation.excludeRaw: true`.
  초기 이전에는 자동 `rolloutRestartTargets`를 넣지 않는다. 정적 값 교체는 서비스별 재읽기/재시작 계획을 별도 검증한다.
- 서비스 비밀값·TLS 개인키·Vault 토큰·unseal key는 Gitops에 커밋하지 않는다.

## 4. Secret 관리 주체 전환

현재 `seed-secrets.yml`이 쓰는 것은 `platform/ghcr-pull`, `data-system/ghcr-pull`,
`cert-manager/cloudflare-dns-api-token`이다. DB Secret을 생성/변경하는 코드가 아니다.
이 role은 **모든 VaultStaticSecret 목적지**와 아래 명시적 인계 목록을 확인해 VSO 대상은 건너뛴다.
CRD가 없어졌어도 인계 기록을 유지하면 오래된 환경변수로 다시 덮어쓰지 않는다.
조회 권한/통신 오류는 VSO 없음으로 취급하지 않고 실패한다. 보호할 Secret이 없을 때도 재생성하지 않고 실패한다.

```yaml
# bootstrap.local.yml에 실제 인계 완료한 대상만 기록한다.
gitops_vso_managed_secrets:
  - cert-manager/cloudflare-dns-api-token
```

기존 Secret의 값을 변경 없이 이전하려면 원본 값 비공개 추출 → 새 KV 경로 CAS=0 등록 → 모든 key/byte 일치 확인 →
기존 생성 도구 중지/인계 목록 등록 → VSO 연결 → UID/type/data 유지와 실제 동기화 성공 확인 순서로 한다.
VSO 연결은 읽기 전용 동작이 아니므로 이전 중 비밀번호 교체를 동시에 수행하지 않는다.
이 PR은 이 작업을 자동 실행하지 않으며, 이미 DB 연동에 성공했다는 사용자 보고를 클러스터 검증 완료로 대신하지 않는다.

| 후속 후보 | 기존 대상/조건 |
|---|---|
| Collector DB | `data-system/collector-db`의 기존 `PGPASSWORD` 그대로 이전 |
| Cloudflare DNS 토큰 | `cert-manager/cloudflare-dns-api-token`의 `api-token`; 인증서 `frontend-tls`는 cert-manager만 관리 |
| 복구 Kafka 인증 | 실제 인증 도입 시 `platform/recovery-controller-credentials`; PLAINTEXT면 추가 불필요 |
| 워커 kubeconfig | IaC/Terraform 등록·삭제 경로와 별도 합의 전 이전하지 않음. 임시 토큰을 정적 복사해 자동 갱신된다고 가정하지 않음 |
| Grafana·Slack | Monitoring 담당의 실제 Secret 참조와 기존 생성 스크립트 인계 후 진행 |
| GHCR·Argo 접근 | Vault/VSO 자체 복구용 초기 인증 수단을 밖에 보관한 뒤 단계적으로 이전 |

Vault 인증·관리 수단과 VSO가 최초 기동하는 데 필요한 값을 Vault 안에만 두지 않는다.

## 5. 3대 확장 (후속 유지보수)

지금은 단일 노드이며 HA가 아니다. `vault_future`는 실행 대상에서 제외되어 있다.
snapshot과 unseal 수단을 확보한 뒤 한 대씩 `vault_servers`로 이동하고 같은 버전으로 구성한다.
추가 노드에서는 **init하지 않고** 기존 클러스터에 Raft join 후 기존 unseal key로 잠금을 해제한다.
각 자체 서명 인증서를 신뢰할 수 있도록 leader/follower TLS 신뢰를 함께 준비한다.
`vault operator raft list-peers`에서 고유 node ID·주소·voter를 확인한다.
2대로 머무르면 한 대 장애도 견디지 못하므로 3대 가입을 마치고 장애 시험을 한다.
접속 주소 HA·인증서 신뢰 배포·백업은 별도 확정하며 `.81` 주소만으로 자동 failover가 되지는 않는다.

## 근거

- [프로젝트 Vault 적용 문서](https://devoops-team.atlassian.net/wiki/spaces/GPUF/pages/29949958)
- [공식 Raft 구성](https://developer.hashicorp.com/vault/docs/configuration/storage/raft)
- [공식 Kubernetes 인증](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [VSO 설치](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/installation)
- [VSO API](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/api-reference)
