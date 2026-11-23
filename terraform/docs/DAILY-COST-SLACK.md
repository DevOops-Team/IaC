# 매일 오전 9시 Slack 비용 알림 (GPU-158)

한국 시간 전날 00:00~24:00의 시간별 사용 비용을 `#aws-비용트래킹`에 보낸다.
최근 3일을 매번 다시 집계하고 AWS 청구월의 크레딧·환불 전/후 합계도 함께 표시한다.

## 구성과 비용

`CUR 2.0(HOURLY) → 전용 S3 → Lambda → Slack Incoming Webhook`

EventBridge Scheduler가 `Asia/Seoul` 오전 9시에 Lambda를 실행한다. EKS/VPC에 의존하지
않는 `terraform/live/cost` 별도 state이므로 GPU·VPN 종료 뒤에도 계속 동작한다.
Cost Explorer API·Athena·별도 NAT Gateway는 추가하지 않는다.

- 실행: Lambda 256 MB, 최대 120초. 실행이 끝나면 실행 시간 과금도 끝난다.
- 저장: S3의 gzip CSV와 manifest. 최신 manifest가 가리키는 실행별 CSV만 읽는다.
  수집 중 갱신된 CSV가 섞이지 않도록 `CREATE_NEW_REPORT`, 90일 수명 주기를 사용한다.
- 비밀: SSM Standard `SecureString`, AWS 관리형 기본 키 사용. Terraform이 값 자체를
  만들거나 읽지 않으므로 코드·plan·state에 Webhook을 넣지 않는다.
- 로그: CloudWatch 14일 보관. Lambda가 Webhook 값·Slack HTTP 원본 오류를 출력하지 않는다.
- 비용은 S3 저장/요청·Lambda·Scheduler·로그 사용량에 따라 달라진다. 월 30회/회당 10초의
  Lambda 예시는 무료 제외 약 $0.0013/월이다. S3 보고서 용량·갱신량은 첫 수신 뒤 확인한다.
  Cost Explorer 일별 API를 쓰던 경우의 월 $0.30 조회료는 이 구성에 적용하지 않는다.

## 비용을 해석하는 기준

전날 상세는 CUR `line_item_usage_type`으로 분류하며, 0이 아닌 항목을 모두 표시한다.
`AmazonEC2` 제품 코드에는 NAT·EBS도 들어 있으므로 인스턴스 실행료로 해석하지 않는다.
EC2 인스턴스는 유형별로, NAT는 시간/데이터 처리로 나누고 EBS·VPN·공인 IPv4·데이터 전송도
따로 표시한다. S3는 저장/요청, DynamoDB는 읽기/쓰기/PITR/저장 비용을 구분한다.
알 수 없는 사용 유형은 제품 코드와 원래 사용 유형을 함께 보존한다.
Export SQL 변경 뒤 새 CSV가 도착하기 전에는 `세부 사용 유형 수신 대기`로 표시하며 추측하지 않는다.
1센트 미만의 0이 아닌 항목은 `$0.01 미만`으로 표시한다. 표시 반올림으로 상세와 합계가 다를 수 있다.

1. SQL과 집계 코드 모두 현재 실행 계정 ID로 필터한다. 다른 연결 계정 비용을 합치지 않는다.
2. 시간대가 있는 UTC 시간별 행의 시작 시각을 KST로 변환한다. 24시간 이내 자료를 단순히
   UTC 일별 금액에 날짜만 바꿔 붙이지 않는다. 일반 일별 합계에는 1시간 이하의 행만 포함한다.
3. `line_item_net_unblended_cost`가 있으면 사용하고, 없으면 `line_item_unblended_cost`를 사용한다.
   일반 할인은 반영하되 Credit/Refund 행은 일별 금액에서 제외한다. Decimal로 계산한다.
4. 월 단위·시간 미지정 요금, Credit/Refund는 특정 하루에 임의 배분하지 않는다.
   AWS 청구월(UTC) 합계에는 포함한다. 월 합계를 한국 달력 월 합계라고 표시하지 않는다.
5. 보고서가 없거나 해당 날짜의 행이 없으면 **미집계**로 표시한다. 비용 $0 확정으로 안내하지 않는다.
   보고서 갱신 시각을 표시하고 현재 청구월 자료가 36시간 넘게 갱신되지 않으면 경고한다.
6. 최근 3일은 다음 알림에서 수정될 수 있는 잠정 금액이다. 확정 청구서는 AWS Billing에서 확인한다.
   전날 이후 시간별 행의 부분 누락 여부를 이 보고서만으로 완전히 판별할 수는 없다.

첫 수집은 최대 24시간 걸릴 수 있고 이후에도 데이터가 지연된다. 오전 9시 전날 비용의 완전성을
보장하지 않는다. 처음에는 보고서 대기 안내만 도착할 수 있다. 과거 행이 3일 이후 수정되면 월 합계에는
반영되지만 최근 3일 표에는 나타나지 않는다.

## 준비·배포

설정은 기존 `terraform/config/prod.yaml`의 project/environment/region을 읽는다. 기존 state·base·eks
실행과 분리해 아래 root만 plan/apply한다. 기존 GPU나 VPN state에 적용하지 않는다.

```powershell
$env:AWS_PROFILE = 'devoops'
terraform -chdir=terraform/live/cost init `
  -backend-config='bucket=<기존 Terraform state 버킷>' `
  -backend-config='key=prod/cost/terraform.tfstate' `
  -backend-config='region=us-east-2' `
  -backend-config='encrypt=true' -backend-config='use_lockfile=true'
terraform -chdir=terraform/live/cost plan -out=cost.tfplan
terraform -chdir=terraform/live/cost apply cost.tfplan
```

`terraform/state/main.tf`의 보호 state 키에도 cost를 추가했다. state root plan에서 기존
버킷 정책의 cost 키 추가만 확인 후 적용하면 cost state에도 기존 삭제 Deny가 적용된다.
그 전에도 backend 암호화·버전 관리·잠금은 기존 state 버킷 설정을 따른다.

초기 Scheduler는 `DISABLED`다. CUR 수집을 먼저 시작하고 다음 Webhook 저장·실제 전달을
검증한 후 `schedule_enabled=true`로 켠다. Lambda·스케줄러의 자동 재시도는 0으로 두어
성공 여부를 알 수 없는 Slack 응답의 중복 전송을 줄인다. 실패는 로그에서 확인하고 수동 재실행한다.
이 일일 요약과 별도의 실패·비용 급증 감시는 후속 범위다.

## Slack 연결

1. [Slack 앱 관리](https://api.slack.com/apps)에서 `Pick features`로 앱을 만든다.
2. 권한은 `incoming-webhook`만, 이벤트 구독은 0개. `channels:history`·`commands`는 필요 없다.
3. 설치 시 `#aws-비용트래킹` 채널을 선택한다. Incoming Webhooks에서 생성된 URL을 확인한다.
4. 터미널에서 아래 스크립트를 실행해 숨김 프롬프트에 붙여 넣는다. URL을 명령 인자·채팅에 넣지 않는다.

```powershell
python -m pip install boto3
python scripts/cost/set_slack_webhook.py --profile devoops --region us-east-2
```

표준 입력이 터미널이 아니면 스크립트가 중단된다. AWS 계정·파라미터 경로만 표시하며
값은 `/devoops/prod/cost/slack-webhook`에 저장한다. 프로필·리전·파라미터 경로는 옵션으로 바꿀 수 있다.

```powershell
# 발송하지 않고 보고서 형식·집계 여부 확인 (AWS CLI v2)
aws lambda invoke --profile devoops --region us-east-2 `
  --function-name devoops-prod-daily-cost --cli-binary-format raw-in-base64-out `
  --payload '{"dry_run":true}' preview.json
# 실제 채널 전달을 한 번 검증
aws lambda invoke --profile devoops --region us-east-2 `
  --function-name devoops-prod-daily-cost --cli-binary-format raw-in-base64-out `
  --payload '{}' result.json
# 저장된 Webhook과 전달 결과 확인 후 매일 일정 활성화
terraform -chdir=terraform/live/cost plan -var='schedule_enabled=true' -out=enable.tfplan
terraform -chdir=terraform/live/cost apply enable.tfplan
```

Webhook은 설치된 채널에 고정된다. 코드의 채널 이름만 바꿔 다른 채널로 보낼 수 없다.
다른 채널로 바꾸려면 Slack에서 새 Webhook을 만든 뒤 같은 SSM 파라미터를 교체한다.

## 검증과 한계

`python -m unittest discover -s scripts/cost/tests -v`와 cost root의 Terraform fmt/validate를 CI에서 실행한다.
테스트는 KST 경계·청구월 경계·다른 계정 배제·크레딧·환불·할인·자료 미수신·manifest 참조·비밀 오류 노출을 확인한다.
실제 CUR manifest와 CSV는 첫 수신 후 추가 대조한다. 현재 리더의 한도는 청구월당 파일 100개,
전체 gzip 파일 64 MiB·200,000행이다. 한도를 넘으면 부분 금액을 보내지 않고 실패한다.
Lambda 120초 시간 제한 초과·권한 오류·파서 오류는 미집계 $0로 대체하지 않는다.

## 근거

- https://docs.aws.amazon.com/cur/latest/userguide/table-dictionary-cur2.html
- https://docs.aws.amazon.com/cur/latest/userguide/dataexports-export-delivery.html
- https://docs.aws.amazon.com/cur/latest/userguide/dataexports-s3-bucket.html
- https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/billing-example-policies.html
- https://docs.aws.amazon.com/scheduler/latest/UserGuide/cross-service-confused-deputy-prevention.html
- https://docs.slack.dev/messaging/sending-messages-using-incoming-webhooks/
