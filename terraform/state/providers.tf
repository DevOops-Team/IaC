# 계정 · 프로파일을 코드에 적지 않는다 (GPU-171). 자격 증명은 AWS_PROFILE(run.sh 기본 devoops)에서,
# 계정 ID는 aws_caller_identity로 읽는다. 어느 계정에 적용하는지는 run.sh가 실행 전에 보여 주고 확인받는다.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Purpose     = "TerraformState"
    }
  }
}
