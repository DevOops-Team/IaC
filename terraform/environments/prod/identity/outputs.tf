output "trust_anchor_arn" {
  value = aws_rolesanywhere_trust_anchor.onprem.arn
}

output "workloads" {
  description = "Public identifiers for signing helper configuration; not session credentials."
  value = {
    for name in local.workloads : name => {
      role_arn            = aws_iam_role.onprem[name].arn
      profile_arn         = aws_rolesanywhere_profile.onprem[name].arn
      certificate_subject = "${local.name_prefix}-${name}"
      credential_process = join(" ", [
        "/usr/local/bin/aws_signing_helper credential-process",
        "--certificate /var/run/devoops-aws/client.pem",
        "--private-key /var/run/devoops-aws/client.key",
        "--trust-anchor-arn ${aws_rolesanywhere_trust_anchor.onprem.arn}",
        "--profile-arn ${aws_rolesanywhere_profile.onprem[name].arn}",
        "--role-arn ${aws_iam_role.onprem[name].arn}",
      ])
    }
  }
}
