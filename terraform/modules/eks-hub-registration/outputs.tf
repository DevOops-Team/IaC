output "onprem_secrets" {
  description = "On-prem Secrets that register this EKS (no secret values)."
  value = {
    multikueue_kubeconfig = "${kubernetes_secret_v1.multikueue_kubeconfig.metadata[0].namespace}/${kubernetes_secret_v1.multikueue_kubeconfig.metadata[0].name}"
    argocd_cluster        = "${kubernetes_secret_v1.argocd_cluster.metadata[0].namespace}/${kubernetes_secret_v1.argocd_cluster.metadata[0].name}"
  }
}

output "argocd_cluster_labels" {
  value = kubernetes_secret_v1.argocd_cluster.metadata[0].labels
}

output "eks_service_accounts" {
  value = {
    multikueue     = "${kubernetes_service_account_v1.multikueue.metadata[0].namespace}/${kubernetes_service_account_v1.multikueue.metadata[0].name}"
    argocd_manager = "${kubernetes_service_account_v1.argocd_manager.metadata[0].namespace}/${kubernetes_service_account_v1.argocd_manager.metadata[0].name}"
  }
}
