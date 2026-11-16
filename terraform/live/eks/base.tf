# live/base의 출력(네트워크 · 버킷 · 펜싱 테이블 · 온프레 역할)을 읽는다. base가 먼저 있어야 한다.
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

# 네트워크가 꺼져 있으면(network.enabled: false) EKS를 만들지 않고 멈춘다
resource "terraform_data" "require_network" {
  lifecycle {
    precondition {
      condition     = local.network != null
      error_message = "base의 네트워크가 없습니다. config network.enabled: true로 base를 먼저 apply하세요."
    }
  }
}
