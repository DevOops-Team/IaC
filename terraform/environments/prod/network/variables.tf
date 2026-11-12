variable "environment" {
  description = "Environment name used in resource names."
  type        = string
  default     = "prod"
}

variable "deployment_profile" {
  description = "test: EKS A/B with 2/0 GPU nodes. full: EKS A/B/C with fixed 4 training + 1 spare each. Both use prod names."
  type        = string
  default     = "test"
  validation {
    condition     = contains(["test", "full"], var.deployment_profile)
    error_message = "Choose test or full explicitly."
  }
}

variable "project_name" {
  description = "Project name used in resource names and tags."
  type        = string
  default     = "devoops"
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block for the project VPC."
  type        = string
  default     = "172.28.0.0/16"
}

variable "subnets" {
  description = "Public and private subnet CIDRs for each Availability Zone."

  type = map(object({
    public_cidr  = string
    private_cidr = string
  }))

  default = {
    us-east-2a = {
      public_cidr  = "172.28.10.0/24"
      private_cidr = "172.28.64.0/20"
    }

    us-east-2b = {
      public_cidr  = "172.28.20.0/24"
      private_cidr = "172.28.80.0/20"
    }

    us-east-2c = {
      public_cidr  = "172.28.30.0/24"
      private_cidr = "172.28.96.0/20"
    }
  }
}

variable "customer_gateway_ip" {
  description = "Current public IPv4 address of the on-premises internet connection."
  type        = string

  validation {
    condition     = can(cidrnetmask("${var.customer_gateway_ip}/32"))
    error_message = "Enter a valid IPv4 address."
  }
}

variable "customer_gateway_asn" {
  description = "BGP ASN used by pfSense."
  type        = number
  default     = 65010
}

variable "amazon_side_asn" {
  description = "BGP ASN used by the AWS Virtual Private Gateway."
  type        = number
  default     = 64512
}

variable "hub_registration" {
  description = <<-EOT
    How Terraform reaches the two Kubernetes APIs that register each EKS with the on-prem hub (GPU-142).
    EKS endpoints are private: run plan/apply with HTTPS_PROXY=socks5://127.0.0.1:1080 over
    ssh -D 1080 k8s-master1 (see EKS-HUB-REGISTRATION.md). The on-prem API is read from a kubeconfig file.
  EOT
  type = object({
    onprem_kubeconfig = optional(string, "~/.kube/devoops-onprem.yaml")
    onprem_context    = optional(string)
    aws_profile       = optional(string, "devoops")
  })
  default = {}
}
