variable "aws_region" {
  description = "AWS region. run.sh passes AWS_REGION (default us-east-2)."
  type        = string
  default     = "us-east-2"
}

variable "project_name" {
  description = "Project name used in resource names and tags."
  type        = string
  default     = "devoops"
}

variable "environment" {
  description = "Environment name used in resource names."
  type        = string
  default     = "prod"
}
