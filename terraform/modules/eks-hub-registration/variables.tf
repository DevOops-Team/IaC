variable "alias" {
  description = "Worker name shared by MultiKueueCluster, the Argo CD destination and both on-prem Secrets (eks-a, eks-b, eks-c)."
  type        = string

  validation {
    condition     = can(regex("^eks-[a-z]$", var.alias))
    error_message = "alias must look like eks-a."
  }
}

variable "cluster_endpoint" {
  description = "Private EKS API endpoint written into both on-prem Secrets."
  type        = string
}

variable "cluster_ca_data" {
  description = "Base64 cluster CA (certificate-authority-data)."
  type        = string
}

variable "admin_access_ready" {
  description = "Admin access policy association ID from modules/eks. Only orders creation after the Terraform role can reach the API."
  type        = string
}
