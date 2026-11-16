# live/eks가 terraform_remote_state로 읽는다. 이름을 바꾸면 live/eks도 같이 고친다.
output "network" {
  description = "VPC · 서브넷 · VPN ID. network.enabled가 false면 null."
  value = local.cfg.network.enabled ? {
    vpc_id             = module.vpc[0].vpc_id
    public_subnet_ids  = module.vpc[0].public_subnet_ids
    private_subnet_ids = module.vpc[0].private_subnet_ids
    vpn_connection_id  = module.vpc[0].vpn_connection_id
  } : null
}

output "checkpoint_bucket" {
  value = { name = module.checkpoint.id, arn = module.checkpoint.arn }
}

output "monitoring_bucket" {
  value = { name = module.monitoring.id, arn = module.monitoring.arn }
}

output "fencing_table" {
  value = { name = module.fencing.name, arn = module.fencing.arn }
}

output "recovery_table" {
  value = { name = module.recovery.name, arn = module.recovery.arn }
}

output "onprem_role_arns" {
  value = module.rolesanywhere.role_arns
}

output "trust_anchor_arn" {
  value = module.rolesanywhere.trust_anchor_arn
}

output "workloads" {
  description = "signing helper 설정용 ARN (자격 증명 아님)."
  value       = module.rolesanywhere.workloads
}
