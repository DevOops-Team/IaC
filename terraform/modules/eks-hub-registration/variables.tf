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
