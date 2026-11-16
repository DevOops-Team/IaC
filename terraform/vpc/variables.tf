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

  # AZ 이름이 리전에 묶여 있어 다른 리전에서는 이 기본값을 바꾼다. 첫 AZ(정렬 기준)에 NAT를 둔다.
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
