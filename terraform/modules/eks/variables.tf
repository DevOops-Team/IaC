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
  default     = "1.35"
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

variable "gpu_instance_types" {
  description = "One-T4 instance types eligible for the fixed GPU Spot node groups."
  type        = list(string)
  default     = ["g4dn.xlarge", "g4dn.2xlarge"]

  validation {
    condition = (
      length(var.gpu_instance_types) > 0 &&
      length(distinct(var.gpu_instance_types)) == length(var.gpu_instance_types) &&
      alltrue([for instance_type in var.gpu_instance_types : contains(["g4dn.xlarge", "g4dn.2xlarge"], instance_type)])
    )
    error_message = "Use a nonempty, unique list drawn from g4dn.xlarge and g4dn.2xlarge (one GPU each)."
  }
}

variable "gpu_training_node_count" {
  type        = number
  description = "Fixed desired/minimum/maximum size of the training Spot group."
  default     = 4
  validation {
    condition     = var.gpu_training_node_count >= 0 && floor(var.gpu_training_node_count) == var.gpu_training_node_count
    error_message = "Use a nonnegative whole number; zero omits the training GPU group."
  }
}

variable "gpu_spare_node_count" {
  type        = number
  description = "Fixed desired/minimum/maximum size of the spare Spot group."
  default     = 1
  validation {
    condition     = var.gpu_spare_node_count >= 0 && floor(var.gpu_spare_node_count) == var.gpu_spare_node_count
    error_message = "Use a nonnegative whole number; zero omits the spare GPU group."
  }
}

variable "gpu_disk_size" {
  description = "Encrypted ephemeral GPU node root disk in GiB; application data belongs in S3."
  type        = number
  default     = 20
}

variable "gpu_ami_release_version" {
  description = "Pinned EKS 1.35 AL2023 NVIDIA AMI release (AWS public SSM, us-east-2)."
  type        = string
  default     = "1.35.9-20261107"
}

variable "addon_versions" {
  description = "Pinned EKS add-on versions compatible with Kubernetes 1.35."
  type        = map(string)

  default = {
    vpc-cni                = "v1.23.2-eksbuild.8"
    coredns                = "v1.14.7-eksbuild.28"
    kube-proxy             = "v1.35.3-eksbuild.69"
    eks-pod-identity-agent = "v1.4.1-eksbuild.3"
  }
}
