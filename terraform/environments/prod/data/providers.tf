provider "aws" {
  region  = "us-east-2"
  profile = "devoops"

  allowed_account_ids = ["354363695096"]

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
