# relocator(재배치 실행기) 전용 자격 증명 (GPU-174). 노드 수정 권한을 MultiKueue 토큰과 나눈다.
# relocator는 온프레 kueue-system/<alias>-relocator-kubeconfig가 있으면 이것만 쓴다 (K8s relocator.py
# RELOCATOR_KUBECONFIG_SECRET). 그래서 relocator가 워커에서 하는 일은 전부 여기 권한에 있어야 한다:
#   노드: GPU 노드 고르기 · 읽기 · cordon+taint      → ClusterRole (노드는 클러스터 범위)
#   training: 옛 잡 Pod · JobSet · Workload 남았는지  → Role (training 네임스페이스만)
# 잡 삭제 · 재제출은 관리 클러스터에서 하므로 워커 쪽 쓰기 권한은 노드 patch뿐이다.

locals {
  relocator_namespace = "training"
}

resource "kubernetes_service_account_v1" "relocator" {
  provider = kubernetes.eks

  metadata {
    name      = "relocator"
    namespace = kubernetes_namespace_v1.this["kueue-system"].metadata[0].name
  }
}

resource "kubernetes_cluster_role_v1" "relocator" {
  provider = kubernetes.eks

  metadata {
    name = "relocator-nodes"
  }
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "patch"]
  }

  depends_on = [terraform_data.api_ready]
}

resource "kubernetes_cluster_role_binding_v1" "relocator" {
  provider = kubernetes.eks

  metadata {
    name = "relocator-nodes"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.relocator.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.relocator.metadata[0].name
    namespace = kubernetes_service_account_v1.relocator.metadata[0].namespace
  }
}

resource "kubernetes_role_v1" "relocator" {
  provider = kubernetes.eks

  metadata {
    name      = "relocator-stop-check"
    namespace = kubernetes_namespace_v1.this[local.relocator_namespace].metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list"]
  }
  rule {
    api_groups = ["jobset.x-k8s.io"]
    resources  = ["jobsets"]
    verbs      = ["get"]
  }
  rule {
    api_groups = ["kueue.x-k8s.io"]
    resources  = ["workloads"]
    verbs      = ["list"]
  }
}

resource "kubernetes_role_binding_v1" "relocator" {
  provider = kubernetes.eks

  metadata {
    name      = "relocator-stop-check"
    namespace = kubernetes_role_v1.relocator.metadata[0].namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.relocator.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.relocator.metadata[0].name
    namespace = kubernetes_service_account_v1.relocator.metadata[0].namespace
  }
}

resource "kubernetes_secret_v1" "relocator_token" {
  provider = kubernetes.eks

  metadata {
    name      = "relocator"
    namespace = kubernetes_service_account_v1.relocator.metadata[0].namespace
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.relocator.metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

# 온프레: relocator Deployment가 읽는 kubeconfig (relocator 토큰만). EKS를 지우면 함께 지워진다.
resource "kubernetes_secret_v1" "relocator_kubeconfig" {
  provider = kubernetes.onprem

  metadata {
    name      = "${var.alias}-relocator-kubeconfig"
    namespace = "kueue-system"
  }
  data = {
    kubeconfig = yamlencode({
      apiVersion = "v1"
      kind       = "Config"
      clusters = [{
        name    = var.alias
        cluster = { server = var.cluster_endpoint, certificate-authority-data = var.cluster_ca_data }
      }]
      users = [{
        name = "${var.alias}-relocator"
        user = { token = kubernetes_secret_v1.relocator_token.data["token"] }
      }]
      contexts = [{
        name    = var.alias
        context = { cluster = var.alias, user = "${var.alias}-relocator" }
      }]
      current-context = var.alias
    })
  }
}
