# GPU-142: 이 root가 만드는 EKS만, 빠짐없이 온프레 허브에 등록되는지 본다.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-2" }
  }
  mock_data "aws_iam_roles" {
    defaults = {
      arns = ["arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_AdministratorAccess_test"]
    }
  }
}

# live/base의 출력 (live/eks/base.tf). 실제 S3 state를 읽지 않는다.
override_data {
  target = data.terraform_remote_state.base
  values = {
    outputs = {
      network = {
        vpc_id            = "vpc-0123456789abcdef0"
        public_subnet_ids = {}
        private_subnet_ids = {
          us-east-2a = "subnet-0aaaaaaaaaaaaaaaa"
          us-east-2b = "subnet-0bbbbbbbbbbbbbbbb"
          us-east-2c = "subnet-0cccccccccccccccc"
        }
        vpn_connection_id = "vpn-0123456789abcdef0"
      }
      checkpoint_bucket = { name = "devoops-prod-ckpt-123456789012-us-east-2", arn = "arn:aws:s3:::devoops-prod-ckpt-123456789012-us-east-2" }
      fencing_table     = { name = "devoops-prod-fencing", arn = "arn:aws:dynamodb:us-east-2:123456789012:table/devoops-prod-fencing" }
      onprem_role_arns = {
        multikueue = "arn:aws:iam::123456789012:role/devoops-prod-onprem-multikueue"
        relocator  = "arn:aws:iam::123456789012:role/devoops-prod-onprem-relocator"
      }
    }
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

run "test_profile_registers_a_and_b" {
  command = plan

  variables {
    deployment_profile = "test"
  }

  assert {
    condition     = toset(keys(output.hub_registration)) == toset(["a", "b"])
    error_message = "test 토폴로지는 EKS A/B만 등록해야 한다."
  }

  assert {
    condition = alltrue([
      for alias, r in output.hub_registration :
      r.onprem_secrets.multikueue_kubeconfig == "kueue-system/eks-${alias}-kubeconfig" &&
      r.onprem_secrets.argocd_cluster == "argocd/cluster-eks-${alias}" &&
      r.onprem_secrets.relocator_kubeconfig == "kueue-system/eks-${alias}-relocator-kubeconfig"
    ])
    error_message = "Secret 이름이 MultiKueueCluster eks-<x> · Argo CD 목적지 · relocator({name}-relocator-kubeconfig)와 같아야 한다."
  }

  assert {
    condition = alltrue([
      for r in values(output.hub_registration) :
      r.argocd_cluster_labels["argocd.argoproj.io/secret-type"] == "cluster" &&
      r.argocd_cluster_labels["devoops.site/gpu-worker"] == "true"
    ])
    error_message = "ApplicationSet gpu-eks-scheduling은 devoops.site/gpu-worker 라벨로 클러스터를 고른다."
  }

  assert {
    condition = alltrue([
      for r in values(output.hub_registration) :
      r.eks_service_accounts.multikueue == "kueue-system/multikueue-sa" &&
      r.eks_service_accounts.argocd_manager == "kube-system/argocd-manager" &&
      r.eks_service_accounts.relocator == "kueue-system/relocator"
    ])
    error_message = "EKS SA 이름: multikueue-sa(Gitops devoops-dispatcher-read가 묶음) · argocd-manager · relocator."
  }

  assert {
    condition     = module.hub_eks_a[0].argocd_cluster_labels != null && length(module.hub_eks_c) == 0
    error_message = "full이 아니면 EKS C를 등록하면 안 된다."
  }
}

run "full_profile_registers_c_too" {
  command = plan

  variables {
    deployment_profile = "full"
  }

  assert {
    condition     = toset(keys(output.hub_registration)) == toset(["a", "b", "c"])
    error_message = "full 토폴로지는 EKS A/B/C를 등록한다."
  }

  assert {
    condition     = output.hub_registration.c.onprem_secrets.argocd_cluster == "argocd/cluster-eks-c"
    error_message = "EKS C는 eks-c로 등록된다."
  }
}
