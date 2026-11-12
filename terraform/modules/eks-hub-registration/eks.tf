# EKS 안에 허브(온프레 관리 클러스터)가 쓸 인증 주체를 만든다 (GPU-142).
#   - kueue-system/multikueue-sa : MultiKueue · dispatcher가 쓰는 토큰 (권한은 아래 ClusterRole + Gitops devoops-dispatcher-read)
#   - kube-system/argocd-manager : 온프레 Argo CD가 Kueue · JobSet 차트(CRD · 웹훅)를 설치하므로 cluster-admin
#   - training/ghcr-pull         : 비공개 trainer · checkpoint 이미지 pull (온프레 platform/ghcr-pull과 같은 값)
# 토큰은 만료 없는 service-account-token Secret이다 (ADR-9, exec 인증 쓰지 않음).

# 관리자 Access Entry가 붙기 전에는 API 호출이 403이므로 그 뒤에 만든다.
resource "terraform_data" "api_ready" {
  input = var.admin_access_ready
}

# Argo CD(eks/scheduling/base/namespaces.yaml)도 같은 네임스페이스를 관리한다. Argo가 붙이는
# 라벨 · 어노테이션은 건드리지 않는다. 등록은 클러스터와 함께 만들고 지우는 것만 지원한다
# (클러스터를 남긴 채 이 모듈만 지우면 Kueue가 든 네임스페이스도 지워진다).
resource "kubernetes_namespace_v1" "this" {
  provider = kubernetes.eks
  for_each = toset(["kueue-system", "training"])

  metadata {
    name = each.key
  }

  lifecycle {
    ignore_changes = [metadata[0].labels, metadata[0].annotations]
  }

  depends_on = [terraform_data.api_ready]
}

# --- MultiKueue -------------------------------------------------------------

resource "kubernetes_service_account_v1" "multikueue" {
  provider = kubernetes.eks

  metadata {
    name      = "multikueue-sa"
    namespace = kubernetes_namespace_v1.this["kueue-system"].metadata[0].name
  }
}

# Kueue v0.20 create-multikueue-kubeconfig.sh 기준, 이 프로젝트가 보내는 batch Job · JobSet만.
# 다른 종류(PyTorchJob 등)를 보내려면 여기 규칙을 먼저 더한다.
resource "kubernetes_cluster_role_v1" "multikueue" {
  provider = kubernetes.eks

  metadata {
    name = "multikueue-sa-role"
  }

  # dispatcher가 용량을 읽는다. 노드 변경은 relocator 역할에만 있다.
  rule {
    api_groups = [""]
    resources  = ["nodes", "pods"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["create", "delete", "get", "list", "watch"]
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs/status"]
    verbs      = ["get"]
  }
  rule {
    api_groups = ["jobset.x-k8s.io"]
    resources  = ["jobsets"]
    verbs      = ["create", "delete", "get", "list", "watch"]
  }
  rule {
    api_groups = ["jobset.x-k8s.io"]
    resources  = ["jobsets/status"]
    verbs      = ["get"]
  }
  rule {
    api_groups = ["kueue.x-k8s.io"]
    resources  = ["workloads"]
    verbs      = ["create", "delete", "get", "list", "watch", "update", "patch"]
  }
  rule {
    api_groups = ["kueue.x-k8s.io"]
    resources  = ["workloads/status"]
    verbs      = ["get", "patch", "update"]
  }
  rule {
    api_groups = ["kueue.x-k8s.io"]
    resources  = ["clusterqueues", "localqueues"]
    verbs      = ["get", "list", "watch"]
  }

  depends_on = [terraform_data.api_ready]
}

resource "kubernetes_cluster_role_binding_v1" "multikueue" {
  provider = kubernetes.eks

  metadata {
    name = "multikueue-sa-crb"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.multikueue.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.multikueue.metadata[0].name
    namespace = kubernetes_service_account_v1.multikueue.metadata[0].namespace
  }
}

resource "kubernetes_secret_v1" "multikueue_token" {
  provider = kubernetes.eks

  metadata {
    name      = "multikueue-sa"
    namespace = kubernetes_service_account_v1.multikueue.metadata[0].namespace
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.multikueue.metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

# --- Argo CD 허브 -------------------------------------------------------------

resource "kubernetes_service_account_v1" "argocd_manager" {
  provider = kubernetes.eks

  metadata {
    name      = "argocd-manager"
    namespace = "kube-system"
  }

  depends_on = [terraform_data.api_ready]
}

resource "kubernetes_cluster_role_binding_v1" "argocd_manager" {
  provider = kubernetes.eks

  metadata {
    name = "argocd-manager"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.argocd_manager.metadata[0].name
    namespace = kubernetes_service_account_v1.argocd_manager.metadata[0].namespace
  }
}

resource "kubernetes_secret_v1" "argocd_manager_token" {
  provider = kubernetes.eks

  metadata {
    name      = "argocd-manager-token"
    namespace = kubernetes_service_account_v1.argocd_manager.metadata[0].namespace
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.argocd_manager.metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

# --- 학습 이미지 pull -------------------------------------------------------------

resource "kubernetes_secret_v1" "ghcr_pull" {
  provider = kubernetes.eks

  metadata {
    name      = "ghcr-pull"
    namespace = kubernetes_namespace_v1.this["training"].metadata[0].name
  }
  type = data.kubernetes_secret_v1.onprem_ghcr_pull.type
  data = data.kubernetes_secret_v1.onprem_ghcr_pull.data
}
