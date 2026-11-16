# state 저장 위치. 버킷 이름에 계정 ID가 들어가 값(bucket · key · region)은 run.sh가 init 때 넣는다.
terraform {
  backend "s3" {}
}
