# live/base의 출력 (네트워크 · 버킷 · 펜싱 테이블 · 온프레 역할). base를 먼저 apply한다.
data "terraform_remote_state" "base" {
  backend = "s3"
  config = {
    bucket = "${local.name_prefix}-tfstate-${local.account_id}-${local.region}"
    key    = "${local.cfg.environment}/base/terraform.tfstate"
    region = local.region
  }
}

locals {
  base    = data.terraform_remote_state.base.outputs
  network = local.base.network
}

# config network.enabled = false로 base를 apply했으면 EKS를 만들 수 없다
resource "terraform_data" "require_network" {
  lifecycle {
    precondition {
      condition     = local.network != null
      error_message = "base의 네트워크가 없습니다. config network.enabled: true로 base를 먼저 apply하세요."
    }
  }
}
