# GPU-142: every EKS this root creates is registered with the on-prem hub, and only those.
mock_provider "aws" {
  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::354363695096:role/test-admin"
    }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-2" }
  }
}

mock_provider "kubernetes" {
  alias = "onprem"
  mock_data "kubernetes_secret_v1" {
    defaults = {
      type = "kubernetes.io/dockerconfigjson"
      data = { ".dockerconfigjson" = "{}" }
    }
  }
}
mock_provider "kubernetes" {
  alias = "eks_a"
}
mock_provider "kubernetes" {
  alias = "eks_b"
}
mock_provider "kubernetes" {
  alias = "eks_c"
}

variables {
  customer_gateway_ip = "192.0.2.10"
}

run "test_profile_registers_a_and_b" {
  command = plan

  variables {
    deployment_profile = "test"
  }

  assert {
    condition     = toset(keys(output.hub_registration)) == toset(["a", "b"])
    error_message = "The test profile has EKS A/B only, so only they are registered."
  }

  assert {
    condition = alltrue([
      for alias, r in output.hub_registration :
      r.onprem_secrets.multikueue_kubeconfig == "kueue-system/eks-${alias}-kubeconfig" &&
      r.onprem_secrets.argocd_cluster == "argocd/cluster-eks-${alias}"
    ])
    error_message = "Secret names must match MultiKueueCluster eks-<x> and the Argo CD destination name."
  }

  assert {
    condition = alltrue([
      for r in values(output.hub_registration) :
      r.argocd_cluster_labels["argocd.argoproj.io/secret-type"] == "cluster" &&
      r.argocd_cluster_labels["devoops.site/gpu-worker"] == "true"
    ])
    error_message = "ApplicationSet gpu-eks-scheduling selects clusters by devoops.site/gpu-worker."
  }

  assert {
    condition = alltrue([
      for r in values(output.hub_registration) :
      r.eks_service_accounts.multikueue == "kueue-system/multikueue-sa" &&
      r.eks_service_accounts.argocd_manager == "kube-system/argocd-manager"
    ])
    error_message = "Gitops binds devoops-dispatcher-read to kueue-system/multikueue-sa."
  }

  assert {
    condition     = module.hub_eks_a.argocd_cluster_labels != null && length(module.hub_eks_c) == 0
    error_message = "EKS C must not be registered without the full profile."
  }
}

run "full_profile_registers_c_too" {
  command = plan

  variables {
    deployment_profile = "full"
  }

  assert {
    condition     = toset(keys(output.hub_registration)) == toset(["a", "b", "c"])
    error_message = "The full profile registers EKS A/B/C."
  }

  assert {
    condition     = output.hub_registration.c.onprem_secrets.argocd_cluster == "argocd/cluster-eks-c"
    error_message = "EKS C registers as eks-c."
  }
}
