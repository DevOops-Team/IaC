# AWS VPN → pfSense HA 자동 동기화 (GPU-270)

`base`의 `terraform apply`가 VPN을 만들거나 터널 구성을 바꾸면 `terraform_data.vpn_sync`가 양쪽 pfSense를 갱신한다. 기존 `terraform/run.sh`와 Windows의 직접 Terraform 실행에 모두 적용된다. `network` 출력은 이 단계 뒤에 확정된다. `run.sh apply base eks --proxy`는 base가 실패하면 EKS 단계로 진행하지 않는다. 다른 프로세스의 병렬 EKS 적용까지 막는 것은 아니다.

```text
AWS VPN 생성·변경
 → 계정·VPN ID·양쪽 SSH 호스트 키·CARP 역할 확인
 → 대기 노드 계획·백업·터널/VTI/BGP peer 갱신
 → 주 노드 재계획·백업·동일 항목 갱신
 → 양쪽 구성 일치·대기 BGP 정지 확인
 → AWS 2터널 UP/경로 수신 + 활성 pfSense BGP 2이웃 Established/경로 수신
 → base 완료 → EKS 생성·등록
```

## 한 번 준비할 설정

실행 PC에 Python 3.10 이상(표준 라이브러리만 사용), AWS CLI v2, OpenSSH가 필요하다. Terraform과 AWS CLI는 같은 계정이어야 한다. CLI는 환경의 임시 자격증명 또는 `AWS_PROFILE`을 사용하며 `sts:GetCallerIdentity`, `ec2:DescribeVpnConnections` 권한이 필요하다.

`scripts/pfsense/vpn-sync.example.json`을 `~/.devoops/pfsense-vpn.local.json`으로 복사한다.

- `ssh_config`, `jump_host`, `identity_file`: 기존 SSH 설정과 키 경로. 키 원문을 넣지 않는다.
- `firewalls`: 서로 다른 두 관리 IP와 각각 콘솔로 검증한 Ed25519 SHA256 지문. 네트워크에서 읽은 키를 검증 없이 신뢰하지 않는다.
- `carp_vip`: 기존 Phase1과 FRR의 VIP 식별자. 새 VIP를 만들거나 `wan` 바인딩으로 바꾸지 않는다.
- `timeout_seconds`: 연결 대기 시간. 기본 240초, 30~600초.

기존 전제는 `vtnet1` CARP VHID1, AWS-Tunnel1/2(IKEv2), `opt1/ipsec1`, `opt2/ipsec2`, 온프레 ASN65010/AWS ASN64512다. 새 설치·VTI 할당·XMLRPC·방화벽 허용 규칙 생성은 범위 밖이다. 다른 토폴로지는 거부한다. 실행 중 GUI 편집·다른 동기화·수동 절체를 겹치지 않는다.

Linux는 기본 `python3`를 사용한다. Windows는 `terraform/live/base/terraform.local.tfvars`에 기존 CA·공인 IP와 함께 다음을 추가한다.

```hcl
vpn_sync = {
  config_path       = "C:/Users/<사용자>/.devoops/pfsense-vpn.local.json"
  python_executable = "python"
}
```

network가 켜져 있는데 JSON 파일이 없으면 plan/apply를 중단한다. Python·SSH·AWS 세션도 미리 준비한다. 방화벽에 도달 불가한 최초 부트스트랩에 한해 `vpn_sync = { enabled = false }`로 명시적으로 끌 수 있지만 VPN 연결 완료를 의미하지 않는다. 준비 후 다시 켜고 base apply한다.

## 실행·재실행

기존 Terraform plan에서 AWS 자원과 `terraform_data.vpn_sync` 변경을 검토한 뒤 apply한다. 셸을 거치지 않고 Python에 환경 JSON을 전달해 경로·공백을 셸 코드로 해석하지 않는다. PSK는 이 단계의 인자·환경·출력으로 전달하지 않는다. AWS CLI에서 메모리로 읽고 검증한 SSH의 표준 입력으로만 보낸다. Terraform AWS provider가 원래 보유하는 민감한 VPN state는 기존 보호 정책을 유지한다.

VPN ID·터널 구성 해시·로컬 접속 설정 해시·스크립트 해시가 바뀌면 동기화한다. Terraform 밖의 pfSense drift는 plan만으로 자동 탐지하지 않는다. AWS를 바꾸지 않고 방화벽 계획만 읽으려면:

```sh
AWS_PROFILE=devoops python3 scripts/pfsense/sync_vpn.py \
  --config ~/.devoops/pfsense-vpn.local.json \
  --vpn-id <현재-VPN-ID> --region us-east-2 --expected-account-id <프로젝트계정ID>
```

`--apply`를 붙이면 동기화·연결 검증을 수행한다. 설정이 같으면 백업·재시작을 생략한다. Terraform으로 재실행하려면 저장 plan을 검토하고 `terraform apply -replace='terraform_data.vpn_sync[0]'`를 사용한다. 실패한 provisioner는 다음 apply에서 재시도된다. 저장 plan을 다른 PC에서 적용할 때는 로컬 파일과 도구·접속 환경도 확인한다.

## 실패·복구

- 쓰기 직전 config.xml SHA256을 대조한다. 모든 편집기와 원자적 트랜잭션을 공유하는 것은 아니므로 동시 운영을 피한다.
- root 전용 `/root/devoops-vpn-sync/<receipt>.xml`에 전체 설정, `.json`에 관리 섹션 복구본을 0600으로 저장한다. PSK가 있으므로 Git·채팅·일반 로그에 올리지 않는다.
- 호출자는 쓰기 전부터 receipt를 보관하므로 쓰기 뒤 SSH 응답 손실 때도 복구를 시도한다.
- 실패하면 변경 노드를 역순으로 복구한다. IPsec Phase1/Phase2·FRR neighbor 섹션만 대상으로 하며 현재 값이 이번 실행 값 또는 원래 값과 다르면 중단한다. 다른 운영자의 변경을 전체 config.xml 복원으로 덮어쓰지 않는다.
- 연결 검증이 실패하면 base apply도 실패한다. AWS 자원을 임의 삭제하지 않는다. 이전 VPN endpoint가 삭제됐다면 설정 복구만으로 과거 VPN 연결까지 살아나지는 않는다.
- 관리망 접속 불가·동시 변경·설정 저장 응답이 모호한 경우 콘솔에서 private 백업과 현재 상태를 비교한다. 자동 복구 성공을 무조건 보장하지 않는다.

`.100` 주소 인계·외부 포트포워딩은 변경하지 않는다. 대기 노드로의 실제 VPN 절체는 별도 시험한다.

## 검증 범위

CI는 AWS·SSH 접속 없이 Python의 HA 순서·응답 손실·분할 상태 거부·비밀값 에러 유출 방지와 PHP의 CARP/VTI/비관리 필드 보존·멱등성·드리프트 거부를 검사한다. 실제 VPN 재생성 → 2터널 UP → EKS API·절체는 다음 AWS 배포 때 기록한다. 코드 검사만으로 실환경 연결 완료라고 보고하지 않는다.

근거: [Terraform terraform_data](https://developer.hashicorp.com/terraform/language/resources/terraform-data), [AWS VPN 조회](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-vpn-connections.html), [pfSense IPsec HA](https://docs.netgate.com/pfsense/en/latest/highavailability/ipsec.html).
