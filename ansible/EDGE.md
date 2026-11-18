# Cloudflare DNS-only + Traefik HTTPS

```text
DNS: devoops.site → 공인 IP (A/AAAA, DNS-only)
HTTPS: 사용자 → 공인 IP:443 → 라우터 → pfSense WAN/VIP의 TCP443 포트 전달
       → 플랫폼 워커:30443 → Traefik(TLS 종료) → frontend
```

- gpu-iac: Cloudflare DNS 레코드. Tunnel·host route·커넥터 Secret 생성은 제거했다.
- Gitops: Traefik NodePort·cert-manager·Certificate·Ingress. DNS01 발급용 Secret은 유지한다.
- gpu-iac의 configure-pfsense-edge.yml: pfSense TCP443 → 지정한 워커:30443 NAT와 연계 방화벽 허용 규칙.
- 네트워크 담당: pfSense 설치·인터페이스/VIP·라우터 TCP443 전달·노드 반환 경로·노드 방화벽. 설치된 pfSense와 SSH/Python이 필요하다.

## 적용

1. Gitops Traefik을 먼저 sync한다. 아래 pfSense 플레이북으로 지정한 워커 IP:30443에 전달한다. NAT는 클라이언트 원본 IP를 유지하므로 노드 반환 경로가 pfSense를 지나야 한다. 노드 30443의 허용 소스는 실제 클라이언트/상위 라우터 NAT 방식에 맞춰 정하고 인터넷에서 노드로 직접 진입하는 경로는 차단한다. HTTP 80·대시보드는 공개하지 않는다.
2. 외부 네트워크에서 `curl --resolve devoops.site:443:PUBLIC_IP https://devoops.site/`로 기존 인증서를 포함한 응답을 확인한다. `-k`는 사용하지 않는다. 인증서는 Traefik이 처리하므로 pfSense TLS 종료·별도 인증서 발급은 하지 않는다.
3. bootstrap.example.yml을 개인 설정 파일로 복사하고 manager_context·cloudflare_zone_id·edge_public_ip를 채운다. 확인 후에만 edge_dns_confirmed: true로 지정한다. 공인 IP가 없거나 443 인바운드가 차단되어 있으면 전환할 수 없다.
4. 환경변수 CLOUDFLARE_DNS_API_TOKEN을 설정한다. 대상 Zone의 DNS 편집 권한만 필요하며 Tunnel/Account 권한은 사용하지 않는다. 기존 DNS01 발급 토큰의 용도도 유지한다. 토큰은 Git에 넣지 않는다.
5. 기존 레코드가 있다면 ID·type·content·proxied·TTL을 백업한다. 변경에는 edge_dns_replace_record_id와 edge_dns_previous_content를 반드시 지정한다. 여러 레코드가 있으면 자동으로 덮어쓰지 않고 실패한다. 공개 IPv4는 A, IPv6는 AAAA를 만든다. IPv6 경로가 검증되지 않았으면 IPv4를 사용한다.

```sh
ansible-playbook ansible/playbooks/network/configure-cloudflare.yml -e @ansible/bootstrap.local.yml
```

DNS-only(proxied=false), TTL 기본 300초다. 동일 설정은 변경하지 않는다. 기존 레코드를 바꿀 때 PATCH를 사용하며 Tunnel CNAME도 명시적 동의 후 A/AAAA로 바꾼다. 목록 조회와 변경은 한 트랜잭션이 아니므로 전환 중 다른 운영자가 같은 레코드를 수정하지 않도록 한다. DNS-only 경로는 Cloudflare 프록시/WAF를 거치지 않는다.

## 기존 Tunnel 정리와 롤백

새 경로 검증·DNS 전환·기존 캐시 만료까지 기존 Tunnel을 유지한다. 이후 Gitops 문서에 따라 Argo Application·Deployment/PDB·token Secret·빈 namespace를 명시적으로 정리한다. prune 비활성 상태에서는 Git 삭제만으로 실제 리소스가 없어지지 않는다. 다른 hostname이 사용하지 않는지 확인하고 Cloudflare Tunnel·전용 토큰도 폐기한다. 이 플레이북은 기존 Tunnel을 자동 삭제하지 않는다.

롤백은 백업한 DNS 레코드로 복원한다. Tunnel을 삭제했다면 이전 Git 구성과 커넥터 자격증명도 먼저 복원해야 한다. 실제 외부 연결과 DNS 변경은 운영 환경에서 별도로 실행·검증한다.


## pfSense 포트 전달 적용 (새로 추가)

이 구현은 HAProxy 패키지 없이 pfSense 기본 DNAT를 사용한다. HTTPS는 그대로 Traefik까지 전달하며 pfSense 인증서·TLS 종료 설정은 만들지 않는다. **진입 워커 한 대 장애에 대한 자동 전환은 제공하지 않는다.** 노드 안에서는 NodePort/Service가 Traefik 복제본으로 분배한다. 다중 워커 상태 검사·자동 전환이 필요하면 후속으로 pfSense HAProxy 구성을 추가한다. 기존 HAProxy가 같은 WAN/VIP:443을 처리 중이면 이 NAT와 동시에 적용하지 않는다.

1. pfSense를 설치하고 관리망 SSH 키 접속·설치된 Python 경로를 확인한다. 모듈은 root 권한으로 실행한다. pfsense 전용 inventory를 사용하며 Kubespray inventory에는 합치지 않는다.
2. GUI에서 설정 백업을 받고 관리 GUI는 LAN/관리망에서 접근 가능한지 확인한다. WAN443 포트 전달은 해당 WAN 주소의 기존 GUI/서비스보다 우선한다. 같은 목적지443의 기존 NAT·HAProxy 규칙이 없어야 한다.
3. `inventory/pfsense/hosts.example.yml`과 `pfsense-edge.example.yml`을 개인 파일로 복사한다. pfSense 관리 IP·Python 경로·정확한 WAN IP 또는 CARP VIP·진입 워커 IP를 채운다. 현재 온프레 inventory의 워커는 172.30.0.21/.22/.23이나 실제 설치값을 확인해야 한다. CARP 구성에서는 primary 한 대만 대상으로 하며 XMLRPC 동기화·보조 노드 반영·절체 검증은 별도다. 이 플레이북은 CARP/설정 동기화를 생성하지 않는다.
4. 상위 라우터가 있으면 공인IP:443을 지정한 pfSense WAN/VIP:443으로 전달한다. 워커의 응답도 pfSense를 경유하도록 라우팅한다. 이 코드는 상위 라우터·노드 라우팅을 변경하지 않는다.
5. 아래 명령을 ansible 디렉터리에서 실행한다. `--check`는 변경 예상만 확인하며 실제 접속을 증명하지 않는다. 먼저 Traefik Application을 sync한다.

```sh
cd ansible
ansible-galaxy collection install -r requirements-pfsense.yml
ansible-playbook -i inventory/pfsense/hosts.local.yml playbooks/network/configure-pfsense-edge.yml -e @pfsense-edge.local.yml --check
ansible-playbook -i inventory/pfsense/hosts.local.yml playbooks/network/configure-pfsense-edge.yml -e @pfsense-edge.local.yml
```

이 플레이북은 기존 설정을 pfSense의 `/cf/conf/config.xml.gpu-edge-*`에 0600 권한으로 백업한 뒤 `gpu-iac-traefik-https` 규칙을 관리한다. 설정 백업에는 비밀정보가 있으므로 Git에 복사하지 않는다. 실제 외부 HTTPS 검증을 통과한 다음에만 DNS 플레이북을 실행한다. 기존 규칙이 이 규칙보다 앞서 트래픽을 처리하는지도 확인한다.

롤백은 같은 입력에 `-e pfsense_edge_state=absent`를 추가하여 이 NAT와 연계 규칙만 제거한다. 전체 config.xml 복원은 다른 운영 변경도 되돌릴 수 있으므로 GUI 복원 절차로 별도 수행한다. IPv6 인바운드는 이번 포트 전달 구현에 포함하지 않으므로 이 경로에서는 DNS A(IPv4)만 적용한다.

근거: [Netgate 포트 전달](https://docs.netgate.com/pfsense/en/latest/nat/port-forwards.html), [pfsensible.core](https://github.com/pfsensible/core).

## EKS → 온프레 IPsec 인바운드

`pfsense-edge`는 HTTPS NAT와 IPsec 규칙을 별도로 실행할 수 있다. 기존 실행은 HTTPS만 관리하며, IPsec은 `pfsense_edge_ipsec_enabled: true`로 명시적으로 켠다. IPsec만 적용할 때는 `pfsense_edge_https_enabled: false`를 사용하므로 WAN/VIP·HTTPS 워커 입력이 필요 없다.

| 출발지 | 목적지 | TCP 목적지 포트 |
|---|---|---|
| `172.28.0.0/16` | 모니터링 VIP `172.30.0.35` | `9009` Mimir, `3100` Loki, `4317`·`4318` Tempo |
| `172.28.0.0/16` | Kafka `172.30.0.40`·`.41`·`.42` | `9092` |

IPsec 탭(`enc0`)에 이름 있는 허용 규칙 두 개와 별칭 두 개를 관리한다. 모니터링 포트는 연속 범위로 열지 않고 네 포트만 지정한다. 별칭과 규칙을 한 번에 계획하므로 최초 `--check`에서도 별칭 참조를 검증할 수 있다. 기존 규칙·NAT·별칭을 일괄 삭제하지 않는다. 요청한 경로를 명시적으로 식별하도록 IPsec 탭 맨 위에 두며, 기존 광역 허용 규칙은 축소하거나 제거하지 않는다.

```sh
cd ansible
ansible-galaxy collection install -r requirements-pfsense.yml
# 예제 파일을 개인 파일로 복사하고 대상·백업을 확인한 후 confirmed=true로 설정한다.
cp pfsense-ipsec.example.yml pfsense-ipsec.local.yml
ansible-playbook -i inventory/pfsense/hosts.local.yml playbooks/network/configure-pfsense-edge.yml -e @pfsense-ipsec.local.yml --limit edge_primary --check
ansible-playbook -i inventory/pfsense/hosts.local.yml playbooks/network/configure-pfsense-edge.yml -e @pfsense-ipsec.local.yml --limit edge_primary
```

inventory 호스트 이름은 실제 파일에 맞춘다. IPsec 필터 모드는 `enc`여야 하고 대상 장비에 IPsec VPN 구성이 있어야 한다. CARP/pfsync는 이 규칙을 대기에 복제하지 않는다. VPN 구성이 있는 대기 장비에 적용하려면 대상을 별도로 지정하고 검증한다. VPN이 없는 대기에 규칙을 넣기 위해 터널·PSK·인터페이스를 자동 생성하지 않는다.

롤백은 같은 명령에 `-e pfsense_edge_ipsec_state=absent`를 추가해 이름 있는 두 규칙만 제거한다. 별칭은 보존한다. 기존 광역 허용 규칙이 남아 있다면 두 규칙을 지워도 해당 통신이 차단되지는 않는다.

적용 후 `pfctl -sr`에서 네 모니터링 포트와 Kafka `9092`를 확인하고, `pfctl -t devoops_eks_kafka_hosts -T show`로 세 브로커 주소를 확인한다. 재실행 `--check`에서 변경0을 확인한다. 실제 EKS에서 VIP TCP 접속 및 지표·로그·트레이스 수신 여부는 VPN·반환 경로·서비스 리스너와 함께 검증한다.

### 2026-11-18 실제 확인

- 주 `.2`에는 기존 `172.28.0.0/16 → any TCP/모든 포트` 규칙이 있어 모니터링도 이미 방화벽상 허용돼 있었다. Kafka만 열렸다는 과거 설명과 다르다. 광역 허용 축소는 별도 검토한다.
- 주 `.2`에 이 role의 모니터링·Kafka 명시 규칙을 실제 적용하고 실규칙과 변경0을 확인했다. CARP MASTER 및 pfsync syncok=1 유지.
- 대기 `.3`은 IPsec VPN 구성이 없어 체크 모드에서 거부됐다. 실제 설정 변경 없음. pfsync 활성화는 IPsec VPN·방화벽 설정 복제를 의미하지 않는다.
- AWS EKS/VPN은 비용 절감으로 내려둔 상태여서 EKS 출발 수집 성공은 미검증이다.
