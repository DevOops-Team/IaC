# 계정 · 프로파일을 코드에 적지 않는다. 자격 증명은 AWS_PROFILE(run.sh: devoops)에서 온다.
provider "aws" {
  region = local.cfg.region

  default_tags {
    tags = {
      Project     = local.cfg.project
      Environment = local.cfg.environment
      ManagedBy   = "Terraform"
    }
  }
}
