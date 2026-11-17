variable "alias" {
  description = "워커 이름 (eks-a · eks-b · eks-c). MultiKueueCluster · Argo CD 목적지 · 온프레 Secret 이름에 쓴다."
  type        = string

  validation {
    condition     = can(regex("^eks-[a-z]$", var.alias))
    error_message = "alias는 eks-a 형식이어야 한다."
  }
}

variable "cluster_endpoint" {
  description = "온프레 Secret에 넣을 EKS private API 주소."
  type        = string
}

variable "cluster_ca_data" {
  description = "클러스터 CA (base64)."
  type        = string
}

variable "admin_access_ready" {
  description = "modules/eks의 관리자 권한 연결 ID. 이 값이 생긴 뒤에 등록을 시작한다 (그 전엔 API가 403)."
  type        = string
}

variable "gpu_quota" {
  description = <<-EOT
    이 클러스터의 학습 · 예비 GPU 수 (config eks.topologies의 training · spare, 노드 1 = GPU 1, ADR-4).
    Argo CD 클러스터 Secret 라벨로 넣고, Gitops ApplicationSet gpu-eks-scheduling이 워커 ClusterQueue
    train-cq · recovery-cq 할당량으로 쓴다 (GPU-199). Gitops에 숫자를 따로 두지 않는다.
  EOT
  type = object({
    training = number
    spare    = number
  })

  validation {
    condition     = var.gpu_quota.training >= 0 && var.gpu_quota.spare >= 0 && floor(var.gpu_quota.training) == var.gpu_quota.training && floor(var.gpu_quota.spare) == var.gpu_quota.spare
    error_message = "gpu_quota.training · spare는 0 이상의 정수여야 한다."
  }
}
