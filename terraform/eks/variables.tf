variable "deployment_profile" {
  description = "test: EKS A/B with 2/0 GPU nodes. full: EKS A/B/C with fixed 4 training + 1 spare each. Both use prod names."
  type        = string
  default     = "test"
  validation {
    condition     = contains(["test", "full"], var.deployment_profile)
    error_message = "Choose test or full explicitly."
  }
}

variable "eks_admin_role_name_regex" {
  description = <<-EOT
    IAM Identity Center가 계정마다 만드는 SSO 관리자 역할(AWSReservedSSO_AdministratorAccess_<suffix>)을 찾는 패턴.
    suffix가 계정마다 달라 이름을 적지 않고 /aws-reserved/sso.amazonaws.com/ 경로에서 찾는다 (정확히 하나여야 함).
  EOT
  type        = string
  default     = "^AWSReservedSSO_AdministratorAccess_"
}

variable "hub_registration" {
  description = <<-EOT
    How Terraform reaches the two Kubernetes APIs that register each EKS with the on-prem hub (GPU-142).
    EKS endpoints are private: run plan/apply with HTTPS_PROXY=socks5://127.0.0.1:1080 over
    ssh -D 1080 k8s-master1 (run.sh --proxy). The on-prem API is read from a kubeconfig file.
    The EKS token uses the same AWS_PROFILE as Terraform.
  EOT
  type = object({
    onprem_kubeconfig = optional(string, "~/.kube/devoops-onprem.yaml")
    onprem_context    = optional(string)
  })
  default = {}
}
