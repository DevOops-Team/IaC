# AWS가 이 CA로 서명된 인증서를 믿게 한다. 처음 만든 CA(박기현 PC, 11/14)의 anchor라 주소 · 이름을 바꾸지 않는다.
resource "aws_rolesanywhere_trust_anchor" "this" {
  name    = "${var.name_prefix}-onprem-ca"
  enabled = true

  source {
    source_type = "CERTIFICATE_BUNDLE"
    source_data {
      x509_certificate_data = var.ca_certificate_pem
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# 추가 CA마다 anchor 하나 (v2 = 노찬경 PC CA, 11/16). 기존 CA 인증서를 끊지 않고 새 CA를 들일 때 쓴다.
# 옛 CA를 없애려면 그 CA로 발급한 인증서를 모두 새 CA로 바꾼 뒤 지운다.
resource "aws_rolesanywhere_trust_anchor" "additional" {
  for_each = var.additional_ca_certificates

  name    = "${var.name_prefix}-onprem-ca-${each.key}"
  enabled = true

  source {
    source_type = "CERTIFICATE_BUNDLE"
    source_data {
      x509_certificate_data = each.value
    }
  }
}
