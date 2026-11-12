# 온프레 관리 클러스터에 이 EKS를 등록한다 (GPU-142).
#   ① kueue-system/<alias>-kubeconfig : Gitops MultiKueueCluster <alias>가 읽는다 (multikueue-sa 토큰만)
#   ② argocd/cluster-<alias>          : 라벨 devoops.site/gpu-worker로 ApplicationSet gpu-eks-scheduling이
#                                       이 클러스터에 Kueue · JobSet · 워커 큐를 배포한다 (GPU-133)
# EKS를 지우면 둘 다 지워져 MultiKueueCluster는 Inactive, Application은 사라진다.

data "kubernetes_secret_v1" "onprem_ghcr_pull" {
  provider = kubernetes.onprem

  metadata {
    name      = "ghcr-pull"
    namespace = "platform"
  }
}

locals {
  multikueue_kubeconfig = yamlencode({
    apiVersion = "v1"
    kind       = "Config"
    clusters = [{
      name    = var.alias
      cluster = { server = var.cluster_endpoint, certificate-authority-data = var.cluster_ca_data }
    }]
    users = [{
      name = "${var.alias}-multikueue-sa"
      user = { token = kubernetes_secret_v1.multikueue_token.data["token"] }
    }]
    contexts = [{
      name    = var.alias
      context = { cluster = var.alias, user = "${var.alias}-multikueue-sa" }
    }]
    current-context = var.alias
  })
}

resource "kubernetes_secret_v1" "multikueue_kubeconfig" {
  provider = kubernetes.onprem

  metadata {
    name      = "${var.alias}-kubeconfig"
    namespace = "kueue-system"
  }
  data = {
    kubeconfig = local.multikueue_kubeconfig
  }
}

resource "kubernetes_secret_v1" "argocd_cluster" {
  provider = kubernetes.onprem

  metadata {
    name      = "cluster-${var.alias}"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
      "devoops.site/gpu-worker"        = "true"
    }
  }
  data = {
    name   = var.alias
    server = var.cluster_endpoint
    config = jsonencode({
      bearerToken     = kubernetes_secret_v1.argocd_manager_token.data["token"]
      tlsClientConfig = { insecure = false, caData = var.cluster_ca_data }
    })
  }

  # Argo CD가 클러스터 Secret에 붙이는 어노테이션은 그대로 둔다.
  lifecycle {
    ignore_changes = [metadata[0].annotations]
  }
}
