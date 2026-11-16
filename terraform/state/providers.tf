# 계정 · 프로파일은 코드에 없다. 자격 증명은 AWS_PROFILE(run.sh가 devoops로 지정).
provider "aws" {
  region = local.cfg.region

  default_tags {
    tags = {
      Project     = local.cfg.project
      Environment = local.cfg.environment
      ManagedBy   = "Terraform"
      Purpose     = "TerraformState"
    }
  }
}
