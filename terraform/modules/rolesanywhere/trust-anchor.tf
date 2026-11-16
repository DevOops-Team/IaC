# AWS가 이 CA로 서명된 인증서를 믿게 한다 (bootstrap/certs.sh의 ca.pem).
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
