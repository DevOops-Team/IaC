locals {
  name_prefix = "${var.project_name}-${var.environment}"

  checkpoint_bucket_name = "${local.name_prefix}-ckpt-354363695096-us-east-2"
  fencing_table_name     = "${local.name_prefix}-fencing"
}