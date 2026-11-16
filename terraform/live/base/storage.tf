# 영속 데이터: 체크포인트 · 모니터링 S3, 펜싱 DynamoDB (config storage · fencing_table)
locals {
  checkpoint_bucket_name = "${local.name_prefix}-${local.cfg.storage.checkpoint.suffix}-${local.account_id}-${local.region}"
  monitoring_bucket_name = "${local.name_prefix}-${local.cfg.storage.monitoring.suffix}-${local.account_id}-${local.region}"
}

module "checkpoint" {
  source                = "../../modules/s3"
  name                  = local.checkpoint_bucket_name
  versioning            = local.cfg.storage.checkpoint.versioning
  bucket_owner_enforced = local.cfg.storage.checkpoint.bucket_owner_enforced
  lifecycle_rules       = local.cfg.storage.checkpoint.lifecycle_rules
}

module "monitoring" {
  source                = "../../modules/s3"
  name                  = local.monitoring_bucket_name
  versioning            = local.cfg.storage.monitoring.versioning
  bucket_owner_enforced = local.cfg.storage.monitoring.bucket_owner_enforced
  lifecycle_rules       = local.cfg.storage.monitoring.lifecycle_rules
}

module "fencing" {
  source    = "../../modules/dynamodb"
  name      = "${local.name_prefix}-fencing"
  hash_key  = local.cfg.fencing_table.hash_key
  pitr_days = local.cfg.fencing_table.pitr_days
}

locals {
  checkpoint_arn = "arn:aws:s3:::${local.checkpoint_bucket_name}"
  monitoring_arn = "arn:aws:s3:::${local.monitoring_bucket_name}"
  fencing_arn    = "arn:aws:dynamodb:${local.region}:${local.account_id}:table/${local.name_prefix}-fencing"
  cluster_arns = [
    for alias in sort(keys(local.cfg.eks.clusters)) : "arn:aws:eks:${local.region}:${local.account_id}:cluster/${local.name_prefix}-eks-${alias}"
  ]
}
