# 1회용 (GPU-171): 예전 data · identity root의 자원 38개를 이 root로 넘겨받는다. 실제 자원은 바뀌지 않는다.
# apply 뒤 이 파일을 지우고, 예전 state에서는 state rm만 한다 (destroy 금지, docs/STATE-BACKEND.md).
# trust anchor · profile ID는 AWS가 정한 값이라 예전 state에서 옮겨 적었다.

import {
  to = module.checkpoint.aws_s3_bucket.this
  id = local.checkpoint_bucket_name
}

import {
  to = module.checkpoint.aws_s3_bucket_versioning.this[0]
  id = local.checkpoint_bucket_name
}

import {
  to = module.checkpoint.aws_s3_bucket_server_side_encryption_configuration.this
  id = local.checkpoint_bucket_name
}

import {
  to = module.checkpoint.aws_s3_bucket_public_access_block.this
  id = local.checkpoint_bucket_name
}

import {
  to = module.checkpoint.aws_s3_bucket_ownership_controls.this[0]
  id = local.checkpoint_bucket_name
}

import {
  to = module.checkpoint.aws_s3_bucket_policy.this
  id = local.checkpoint_bucket_name
}

import {
  to = module.checkpoint.aws_s3_bucket_lifecycle_configuration.this[0]
  id = local.checkpoint_bucket_name
}

import {
  to = module.monitoring.aws_s3_bucket.this
  id = local.monitoring_bucket_name
}

import {
  to = module.monitoring.aws_s3_bucket_server_side_encryption_configuration.this
  id = local.monitoring_bucket_name
}

import {
  to = module.monitoring.aws_s3_bucket_public_access_block.this
  id = local.monitoring_bucket_name
}

import {
  to = module.monitoring.aws_s3_bucket_policy.this
  id = local.monitoring_bucket_name
}

import {
  to = module.monitoring.aws_s3_bucket_lifecycle_configuration.this[0]
  id = local.monitoring_bucket_name
}

import {
  to = module.fencing.aws_dynamodb_table.this
  id = "${local.name_prefix}-fencing"
}

import {
  to = module.rolesanywhere.aws_rolesanywhere_trust_anchor.this
  id = "e64f2c94-9faa-4510-9e0d-b04c71170678"
}

locals {
  import_profile_ids = {
    "backend"    = "f2a1f629-60ef-4d78-ab5a-c3209efb6c43"
    "db-backup"  = "f844f1e9-a287-4726-b952-5a722647bc4c"
    "loki"       = "b02bf523-d71c-440d-8da1-6b7c17f0f7a5"
    "mimir"      = "dfe0b1b8-4e83-46eb-8cb9-c929e19a4828"
    "multikueue" = "5fa6a7a8-49b9-4041-a5c5-498027cf0ce2"
    "recovery"   = "9c199e1c-3400-49fa-9ad5-d5c945425d7f"
    "relocator"  = "b6e102f3-7bc6-4558-ac62-7c5672fe2eb5"
    "tempo"      = "1bb6f08f-fa74-49f2-89fe-14b907aecaef"
  }
}

import {
  for_each = toset(local.cfg.onprem_workloads)
  to       = module.rolesanywhere.module.role[each.key].aws_iam_role.this
  id       = "${local.name_prefix}-onprem-${each.key}"
}

import {
  for_each = toset(local.cfg.onprem_workloads)
  to       = module.rolesanywhere.module.role[each.key].aws_rolesanywhere_profile.this
  id       = local.import_profile_ids[each.key]
}

import {
  for_each = local.onprem_policies
  to       = module.rolesanywhere.module.role[each.key].aws_iam_role_policy.this[0]
  id       = "${local.name_prefix}-onprem-${each.key}:${each.value.name}"
}
