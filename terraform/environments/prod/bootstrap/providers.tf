provider "aws" {
  region              = "us-east-2"
  profile             = "nochan"
  allowed_account_ids = ["947027666399"]
  default_tags {
    tags = {
      Project     = "devoops"
      Environment = "prod"
      ManagedBy   = "Terraform"
      Purpose     = "TerraformState"
    }
  }
}
