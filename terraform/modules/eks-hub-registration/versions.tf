terraform {
  required_providers {
    kubernetes = {
      source                = "hashicorp/kubernetes"
      version               = "~> 3.0"
      configuration_aliases = [kubernetes.eks, kubernetes.onprem]
    }
  }
}
