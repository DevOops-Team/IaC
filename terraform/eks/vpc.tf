# vpc root의 출력을 읽는다. run.sh는 vpc를 먼저 apply한다. vpc가 없으면 여기서 실패한다.
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket = "${local.name_prefix}-tfstate-${local.account_id}-${local.region}"
    key    = "${var.environment}/vpc/terraform.tfstate"
    region = local.region
  }
}

locals {
  vpc_id             = data.terraform_remote_state.vpc.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.vpc.outputs.private_subnet_ids
  # EKS A/B/C의 CPU 노드는 정렬한 AZ 1 · 2 · 3번째에 하나씩 둔다.
  azs = sort(keys(local.private_subnet_ids))
}
