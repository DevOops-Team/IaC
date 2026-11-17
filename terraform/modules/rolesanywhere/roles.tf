# 워크로드마다 IAM 역할 + Roles Anywhere profile + 인라인 정책 (role/)
module "role" {
  source   = "./role"
  for_each = var.workloads

  name_prefix = var.name_prefix
  workload    = each.key
  account_id  = var.account_id
  # 역할은 모든 anchor(처음 + 추가)로 들어온 세션을 받는다
  trust_anchor_arns = concat(
    [aws_rolesanywhere_trust_anchor.this.arn],
    [for a in aws_rolesanywhere_trust_anchor.additional : a.arn],
  )
  policy_name = each.value.policy_name
  policy_json = each.value.policy_json
}
