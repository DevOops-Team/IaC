variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "onprem_access_roles" {
  description = "On-prem IAM roles mapped to Kubernetes groups; GitOps owns the scoped RBAC bindings."
  type = map(object({
    principal_arn     = string
    kubernetes_groups = list(string)
  }))
  default = {}
}

variable "checkpoint_bucket_arn" {
  description = "ARN of the persistent bucket managed by the prod/data root."
  type        = string
}

variable "fencing_table_arn" {
  description = "ARN of the persistent fencing table managed by prod/data."
  type        = string
}

variable "project_name" {
  description = "Project tag propagated to EC2 instances."
  type        = string
}

variable "environment" {
  description = "Environment tag propagated to EC2 instances."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS."
  type        = string
  default     = "1.37"
}

variable "vpc_id" {
  description = "VPC containing the EKS cluster."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs keyed by Availability Zone."
  type        = map(string)
}

variable "service_ipv4_cidr" {
  description = "Kubernetes Service IPv4 CIDR."
  type        = string
}

variable "onprem_cidr" {
  description = "On-premises network allowed to access the private API."
  type        = string
}

variable "admin_role_arn" {
  description = "IAM role granted cluster administrator access."
  type        = string
}


variable "cpu_instance_type" {
  description = "Instance type for the system CPU node."
  type        = string
  default     = "t3.large"
}

variable "cpu_node_az" {
  description = "Availability Zone for the CPU node group."
  type        = string
}

variable "cpu_disk_size" {
  description = "CPU node root disk size in GiB."
  type        = number
  default     = 30
}

variable "addon_versions" {
  description = "Pinned EKS add-on versions compatible with Kubernetes 1.37."
  type        = map(string)

  default = {
    vpc-cni                = "v1.23.2-eksbuild.8"
    coredns                = "v1.14.7-eksbuild.28"
    kube-proxy             = "v1.37.0-eksbuild.34"
    eks-pod-identity-agent = "v1.4.1-eksbuild.3"
  }
}
