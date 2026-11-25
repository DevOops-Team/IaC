# GPU-270: 직접 terraform apply를 실행해도 새 VPN 정보를 양쪽 pfSense에 반영한다.
variable "vpn_sync" {
  description = "VPN HA 동기화. SSH 접속 정보는 Git 밖 JSON에 두고 Python·AWS CLI·OpenSSH가 설치된 PC에서 실행한다."
  type = object({
    enabled           = optional(bool, true)
    config_path       = optional(string, "~/.devoops/pfsense-vpn.local.json")
    python_executable = optional(string, "python3")
  })
  default = {}
}

resource "terraform_data" "vpn_sync" {
  count = local.cfg.network.enabled && var.vpn_sync.enabled ? 1 : 0

  triggers_replace = {
    vpn_id          = module.vpc[0].vpn_connection_id
    vpn_revision    = module.vpc[0].vpn_sync_revision
    settings_sha256 = try(filesha256(pathexpand(var.vpn_sync.config_path)), "missing")
    python_sha256   = filesha256("${path.module}/../../../scripts/pfsense/sync_vpn.py")
    php_sha256      = filesha256("${path.module}/../../../scripts/pfsense/vpn-sync.php")
  }

  lifecycle {
    precondition {
      condition     = fileexists(pathexpand(var.vpn_sync.config_path))
      error_message = "pfSense VPN 동기화 JSON이 필요합니다. scripts/pfsense/vpn-sync.example.json을 레포 밖에 복사하고 양쪽 SSH 지문을 콘솔로 검증하세요."
    }
  }

  provisioner "local-exec" {
    # 셸을 통하지 않는다. 경로/JSON을 셸 명령으로 보간하지 않고 환경으로 전달한다.
    interpreter = [var.vpn_sync.python_executable, abspath("${path.module}/../../../scripts/pfsense/sync_vpn.py")]
    command     = "terraform"
    quiet       = true
    environment = {
      DEVOOPS_VPN_SYNC = jsonencode({
        config              = abspath(pathexpand(var.vpn_sync.config_path))
        vpn_id              = module.vpc[0].vpn_connection_id
        region              = local.region
        expected_account_id = local.account_id
        apply               = true
      })
    }
  }
}
