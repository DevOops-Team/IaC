# 워크로드마다 IAM 역할 + Roles Anywhere profile + 인라인 정책 (role/)
module "role" {
  source   = "./role"
  for_each = var.workloads

  name_prefix      = var.name_prefix
  workload         = each.key
  account_id       = var.account_id
  trust_anchor_arn = aws_rolesanywhere_trust_anchor.this.arn
  policy_name      = each.value.policy_name
  policy_json      = each.value.policy_json
}
