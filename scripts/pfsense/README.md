# AWS VPN inbound policy

2026-11-13 사용자 확인: 현재 통신 범위를 그대로 코드화. 범위 축소는 별도 검토.
방화벽 전체 규칙의 ADR은 추후 한 번에 정리하며 이번 작업에서 작성하지 않음.

| 항목 | 현재 유지 범위 |
|---|---|
| 수신 인터페이스 | IPsec 탭 `enc0` (필터 모드 `enc`) |
| 출발지 | AWS `172.28.0.0/16` |
| 목적지 | 전체 |
| 프로토콜 / 포트 | IPv4 TCP / 전체 포트 |
| 정책 | 허용 |

`vpn-inbound-policy.json`이 유지할 범위다. 같은 활성 규칙이 있으면 설명·tracker·순서를
바꾸지 않고 그대로 유지한다. 따라서 GUI에서 추가한 설명 없는 기존 규칙도 중복 생성하지 않는다.
같은 규칙이 여러 개거나, 관리 대상 이름의 규칙이 다른 범위로 바뀌면 중단한다.
같은 범위가 비활성화되거나 스케줄·정책 라우팅 등 특수 제어를 가지면 새 허용 규칙으로 우회하지 않고 중단한다.
없으면 기존 규칙 끝에 한 개를 추가한다. 앞선 차단 규칙이 있으면 우선하므로 적용 뒤 실제 동작 검증 필요.
LAN/WAN, NAT, CARP, IPsec 터널·PSK, FRR, Terraform 및 ON/OFF 스크립트는 수정하지 않는다.

## 읽기 검토 (Windows PowerShell)

저장소 루트에서:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\pfsense\Invoke-VpnInboundPolicy.ps1
```

기본값은 `plan`, 주 방화벽 `172.30.0.2`, SSH 경유 `pve4`다. 설정 저장·필터 reload 없음.
`keep_existing`이면 같은 기존 규칙을 유지하고, `append_rule`이면 한 개 추가 예정이다.
출력에는 비밀번호·VPN PSK·전체 XML이 포함되지 않는다.

## 적용 (사용자 검토 후)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\pfsense\Invoke-VpnInboundPolicy.ps1 -Mode apply -ConfirmApply -ExpectedConfigSha256 PLAN_OUTPUT_CONFIG_SHA256
```

추가가 필요한 경우에만 pfSense 내부에 0600 XML 백업 후 설정 저장·필터 reload 요청.
plan 이후 설정 파일이 바뀌면 재검토한다. GUI에서 동시에 설정을 편집하지 않는다.
reload 요청 성공은 통신 검증 완료를 의미하지 않는다. IPsec 규칙과 AWS→온프레 통신을 별도 확인한다.
백업은 인증 정보를 포함하므로 Git/Slack/출력으로 반출하지 않는다. 실패 시 오류와 백업 경로를
확인하고 GUI의 Diagnostics → Backup & Restore에서 검토 후 복원한다. 자동 전체 복원은 하지 않는다.

## 보조 방화벽

이 명령은 지정한 한 대만 대상으로 한다. CARP의 MASTER/BACKUP 전환이 설정 자동 동기화를
보장하지 않는다. 주 장비에서 HA 설정 동기화 항목이 조회되지 않았으며, 보조 장비 상태는 미검증이다.
자동 전파를 가정하거나 보조 장비에도 즉시 적용하지 않는다.
보조 장비 `172.30.0.3`은 콘솔 등 신뢰 경로로 SSH fingerprint를 별도로 확인한 뒤
`-Firewall 172.30.0.3 -HostKeyFingerprint VERIFIED_BACKUP_FINGERPRINT`로 **plan부터** 진행한다.
기본 주 장비 fingerprint를 보조 장비에 그대로 사용하면 검증 실패로 중단한다.

현재 규칙은 TCP만 허용하며 UDP/ICMP 허용을 뜻하지 않는다. 다른 규칙은 별도 관리 대상이다.

## 검증

`php scripts/pfsense/tests/test-vpn-inbound.php`로 기존 설명 없는 규칙 유지,
중복·비활성·범위 변경 거부 등을 검사한다. pfSense 라이브러리나 실제 설정은 읽지 않는 테스트다.
CI에서도 PHP 문법과 같은 검사를 실행한다. 실제 장비 적용·장애 전환 검증은 포함하지 않는다.
