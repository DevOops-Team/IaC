variable "cluster_name" {
  description = "EKS 클러스터 이름."
  type        = string
}

variable "onprem_access_roles" {
  description = "온프레 IAM 역할 => Kubernetes 그룹 (RBAC는 Gitops)."
  type = map(object({
    principal_arn     = string
    kubernetes_groups = list(string)
  }))
  default = {}
}

variable "checkpoint_bucket_arn" {
  description = "체크포인트 버킷 ARN (live/base)."
  type        = string
}

variable "fencing_table_arn" {
  description = "펜싱 테이블 ARN (live/base)."
  type        = string
}

variable "project_name" {
  description = "EC2 인스턴스에 붙일 Project 태그."
  type        = string
}

variable "environment" {
  description = "EC2 인스턴스에 붙일 Environment 태그."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes 버전."
  type        = string
  default     = "1.35"
}

variable "vpc_id" {
  description = "클러스터가 들어갈 VPC."
  type        = string
}

variable "private_subnet_ids" {
  description = "AZ => 프라이빗 서브넷 ID."
  type        = map(string)
}

variable "service_ipv4_cidr" {
  description = "Kubernetes Service CIDR (클러스터마다 달라야 함)."
  type        = string
}

variable "onprem_cidr" {
  description = "private API에 접근을 허용할 온프레 대역."
  type        = string
}

variable "admin_role_arn" {
  description = "클러스터 관리자 권한을 받을 IAM 역할 (SSO 관리자)."
  type        = string
}


variable "cpu_instance_type" {
  description = "시스템 CPU 노드 인스턴스 유형."
  type        = string
  default     = "t3.large"
}

variable "cpu_node_az" {
  description = "워커 노드를 둘 AZ."
  type        = string
}

variable "cpu_disk_size" {
  description = "CPU 노드 루트 디스크 (GiB)."
  type        = number
  default     = 30
}

variable "gpu_instance_types" {
  description = "GPU Spot 노드그룹에 허용할 유형 (T4 1장짜리)."
  type        = list(string)
  default     = ["g4dn.xlarge", "g4dn.2xlarge"]

  validation {
    condition = (
      length(var.gpu_instance_types) > 0 &&
      length(distinct(var.gpu_instance_types)) == length(var.gpu_instance_types) &&
      alltrue([for instance_type in var.gpu_instance_types : contains(["g4dn.xlarge", "g4dn.2xlarge"], instance_type)])
    )
    error_message = "g4dn.xlarge · g4dn.2xlarge 중에서 중복 없이 하나 이상 골라야 한다."
  }
}

variable "gpu_training_node_count" {
  type        = number
  description = "학습 GPU 그룹 대수 (최소=희망=최대)."
  default     = 4
  validation {
    condition     = var.gpu_training_node_count >= 0 && floor(var.gpu_training_node_count) == var.gpu_training_node_count
    error_message = "0 이상의 정수여야 한다. 0이면 학습 그룹을 만들지 않는다."
  }
}

variable "gpu_spare_node_count" {
  type        = number
  description = "예비 GPU 그룹 대수 (최소=희망=최대)."
  default     = 1
  validation {
    condition     = var.gpu_spare_node_count >= 0 && floor(var.gpu_spare_node_count) == var.gpu_spare_node_count
    error_message = "0 이상의 정수여야 한다. 0이면 예비 그룹을 만들지 않는다."
  }
}

variable "gpu_disk_size" {
  description = "GPU 노드 루트 디스크 (GiB, 암호화). 학습 데이터는 S3에 둔다."
  type        = number
  default     = 20
}

variable "gpu_ami_release_version" {
  description = "고정한 EKS 1.35 AL2023 NVIDIA AMI 릴리스 (AWS SSM에서 확인한 값)."
  type        = string
  default     = "1.35.9-20261107"
}

variable "addon_versions" {
  description = "Kubernetes 1.35와 맞춘 애드온 버전 고정."
  type        = map(string)

  default = {
    vpc-cni                = "v1.23.2-eksbuild.8"
    coredns                = "v1.14.7-eksbuild.28"
    kube-proxy             = "v1.35.3-eksbuild.69"
    eks-pod-identity-agent = "v1.4.1-eksbuild.3"
  }
}
