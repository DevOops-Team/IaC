output "trust_anchor_arn" {
  value = aws_rolesanywhere_trust_anchor.this.arn
}

output "role_arns" {
  value = { for name, role in module.role : name => role.role_arn }
}

output "workloads" {
  description = "signing helper 설정용 ARN과 credential_process 예시 (자격 증명 아님)."
  value = {
    for name, role in module.role : name => {
      role_arn            = role.role_arn
      profile_arn         = role.profile_arn
      certificate_subject = "${var.name_prefix}-${name}"
      credential_process = join(" ", [
        "/usr/local/bin/aws_signing_helper credential-process",
        "--certificate /var/run/devoops-aws/client.pem",
        "--private-key /var/run/devoops-aws/client.key",
        "--trust-anchor-arn ${aws_rolesanywhere_trust_anchor.this.arn}",
        "--profile-arn ${role.profile_arn}",
        "--role-arn ${role.role_arn}",
      ])
    }
  }
}
