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
    EKS를 온프레 허브(Argo CD · MultiKueue)에 등록할 때 쓰는 접속 정보 (GPU-142).
    EKS API는 private이라 run.sh --proxy(ssh -D 1080 k8s-master1)로 plan · apply한다.
    EKS 토큰은 Terraform과 같은 AWS_PROFILE을 쓴다.
  EOT
  type = object({
    onprem_kubeconfig = optional(string, "~/.kube/devoops-onprem.yaml")
    onprem_context    = optional(string)
  })
  default = {}
}
