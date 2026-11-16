output "onprem_secrets" {
  description = "이 EKS를 등록한 온프레 Secret 이름 (비밀값 없음)."
  value = {
    multikueue_kubeconfig = "${kubernetes_secret_v1.multikueue_kubeconfig.metadata[0].namespace}/${kubernetes_secret_v1.multikueue_kubeconfig.metadata[0].name}"
    argocd_cluster        = "${kubernetes_secret_v1.argocd_cluster.metadata[0].namespace}/${kubernetes_secret_v1.argocd_cluster.metadata[0].name}"
    relocator_kubeconfig  = "${kubernetes_secret_v1.relocator_kubeconfig.metadata[0].namespace}/${kubernetes_secret_v1.relocator_kubeconfig.metadata[0].name}"
  }
}

output "argocd_cluster_labels" {
  value = kubernetes_secret_v1.argocd_cluster.metadata[0].labels
}

output "eks_service_accounts" {
  value = {
    multikueue     = "${kubernetes_service_account_v1.multikueue.metadata[0].namespace}/${kubernetes_service_account_v1.multikueue.metadata[0].name}"
    argocd_manager = "${kubernetes_service_account_v1.argocd_manager.metadata[0].namespace}/${kubernetes_service_account_v1.argocd_manager.metadata[0].name}"
    relocator      = "${kubernetes_service_account_v1.relocator.metadata[0].namespace}/${kubernetes_service_account_v1.relocator.metadata[0].name}"
  }
}
