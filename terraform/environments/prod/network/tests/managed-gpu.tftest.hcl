# A mocked provider guarantees these topology checks cannot create AWS resources.
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

variables {
  customer_gateway_ip = "192.0.2.10"
}

run "three_fixed_spot_gpu_clusters" {
  command = plan

  variables {
    deployment_profile = "full"
  }

  assert {
    condition     = toset(keys(output.eks_clusters)) == toset(["a", "b", "c"])
    error_message = "Exactly EKS A/B/C must be configured."
  }

  assert {
    condition = alltrue([
      for alias, cluster in output.eks_clusters :
      cluster.name == "devoops-prod-eks-${alias}" &&
      cluster.cpu_node_group == "devoops-prod-eks-${alias}-cpu" &&
      cluster.cpu.capacity_type == "ON_DEMAND" &&
      cluster.cpu.scaling.min_size == 1 && cluster.cpu.scaling.desired_size == 1 && cluster.cpu.scaling.max_size == 1 &&
      toset(keys(cluster.gpu_node_groups)) == toset(["training", "spare"])
    ])
    error_message = "Each cluster needs a CPU group and distinct training/spare GPU groups."
  }

  assert {
    condition = alltrue(flatten([
      for alias, cluster in output.eks_clusters : [
        for role, group in cluster.gpu_node_groups :
        group.capacity_type == "SPOT" &&
        toset(group.instance_types) == toset(["g4dn.xlarge", "g4dn.2xlarge"]) &&
        group.scaling.min_size == (role == "training" ? 4 : 1) &&
        group.scaling.desired_size == group.scaling.min_size &&
        group.scaling.max_size == group.scaling.min_size &&
        group.az == "us-east-2${alias}"
      ]
    ]))
    error_message = "Groups must target 4+1 fixed Spot nodes in the cluster's AZ, using the approved two types."
  }

  assert {
    condition = alltrue([
      for cluster in values(output.eks_clusters) :
      cluster.gpu_node_groups.training.labels["devoops/gpu"] == "true" &&
      !contains(keys(cluster.gpu_node_groups.training.labels), "devoops/spare") &&
      cluster.gpu_node_groups.spare.labels["devoops/spare"] == "true" &&
      length([for t in cluster.gpu_node_groups.training.taints : t if t.key == "devoops/spare"]) == 0 &&
      length([for t in cluster.gpu_node_groups.spare.taints : t if t.key == "devoops/spare" && t.effect == "NO_SCHEDULE"]) == 1
    ])
    error_message = "Only the spare group may carry the spare label/taint."
  }

  assert {
    condition     = length(distinct([for cluster in values(output.eks_clusters) : cluster.service_cidr])) == 3
    error_message = "Each cluster requires a distinct Service CIDR."
  }

  assert {
    condition = length([
      for t in yamldecode(output.gpu_bootstrap.device_plugin_values).tolerations : t
      if t.key == "devoops/spare" && t.value == "true"
    ]) == 1
    error_message = "The NVIDIA plugin must tolerate the spare-node taint."
  }
}

run "two_cluster_test_without_autoscaling" {
  command = plan

  variables {
    deployment_profile = "test"
  }

  assert {
    condition     = toset(keys(output.eks_clusters)) == toset(["a", "b"])
    error_message = "Test mode must create only A and B."
  }

  assert {
    condition = (
      toset(keys(output.eks_clusters.a.gpu_node_groups)) == toset(["training"]) &&
      toset(output.eks_clusters.a.gpu_node_groups.training.instance_types) == toset(["g4dn.xlarge"]) &&
      output.eks_clusters.a.gpu_node_groups.training.capacity_type == "SPOT" &&
      output.eks_clusters.a.gpu_node_groups.training.scaling.min_size == 2 &&
      output.eks_clusters.a.gpu_node_groups.training.scaling.desired_size == 2 &&
      output.eks_clusters.a.gpu_node_groups.training.scaling.max_size == 2 &&
      length(output.eks_clusters.b.gpu_node_groups) == 0
    )
    error_message = "Test A must have exactly 2 fixed g4dn.xlarge Spot workers (8 vCPU); B must have no GPU group."
  }

  assert {
    condition = alltrue([for cluster in values(output.eks_clusters) :
      cluster.cpu.capacity_type == "ON_DEMAND" &&
      toset(cluster.cpu.instance_types) == toset(["t3.large"]) &&
      cluster.cpu.scaling.min_size == 1 && cluster.cpu.scaling.desired_size == 1 && cluster.cpu.scaling.max_size == 1
    ])
    error_message = "Both test clusters retain the system CPU group."
  }
}
