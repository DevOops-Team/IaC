# 온프레 워크로드별 AWS 권한 (Roles Anywhere). 목록은 config onprem_workloads.
# 계약에서 확인된 동작만 넣는다. 정책이 없는 워크로드는 역할 · profile만 만든다.
locals {
  onprem_policies = merge({
    backend = {
      name = "backend-data-access"
      statements = [
        {
          Sid      = "WriteSubmissionAndDatasets"
          Effect   = "Allow"
          Action   = ["s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
          Resource = ["${local.checkpoint_arn}/code/*", "${local.checkpoint_arn}/datasets/*"]
        },
        {
          Sid      = "CreateAndReadInitialFencing"
          Effect   = "Allow"
          Action   = ["dynamodb:PutItem", "dynamodb:GetItem"]
          Resource = local.fencing_arn
        },
      ]
    }
    recovery = {
      name = "recovery-fencing-access"
      statements = [{
        Sid      = "ManageRecoveryState"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
        Resource = local.fencing_arn
      }]
    }
    relocator = {
      name = "relocator-data-access"
      statements = [
        {
          Sid      = "UpdateRelocationState"
          Effect   = "Allow"
          Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
          Resource = local.fencing_arn
        },
        {
          Sid      = "ReadSubmittedJobSet"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "${local.checkpoint_arn}/code/*/jobset.json"
        },
        {
          Sid       = "DescribeWorkerInstances"
          Effect    = "Allow"
          Action    = "ec2:DescribeInstances"
          Resource  = "*"
          Condition = { StringEquals = { "aws:RequestedRegion" = local.region } }
        },
        {
          Sid      = "DiscoverWorkerCluster"
          Effect   = "Allow"
          Action   = "eks:DescribeCluster"
          Resource = local.cluster_arns
        },
      ]
    }
    multikueue = {
      name = "worker-cluster-discovery"
      statements = [{
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = local.cluster_arns
      }]
    }
    # GPU-128 / ADR-31: DB VM은 백업 업로드만. 복구 다운로드는 운영자 SSO로 한다
    db-backup = {
      name = "db-backup-write-only"
      statements = [{
        Sid      = "UploadDatabaseBackups"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = "${local.checkpoint_arn}/backups/db/*"
      }]
    }
    }, {
    # Mimir · Loki · Tempo: 모니터링 버킷의 자기 prefix만
    for w in ["mimir", "loki", "tempo"] : w => {
      name = "${w}-s3-access"
      statements = [
        {
          Sid       = "ListOwnPrefix"
          Effect    = "Allow"
          Action    = "s3:ListBucket"
          Resource  = local.monitoring_arn
          Condition = { StringLike = { "s3:prefix" = "${w}/*" } }
        },
        {
          Sid    = "ManageOwnObjects"
          Effect = "Allow"
          Action = concat([
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:AbortMultipartUpload",
            "s3:ListMultipartUploadParts",
          ], w == "tempo" ? ["s3:GetObjectTagging", "s3:PutObjectTagging"] : [])
          Resource = "${local.monitoring_arn}/${w}/*"
        },
      ]
    }
  })
}

module "rolesanywhere" {
  source             = "../../modules/rolesanywhere"
  name_prefix        = local.name_prefix
  account_id         = local.account_id
  ca_certificate_pem = file(pathexpand(var.ca_certificate_path))
  additional_ca_certificates = {
    for name, path in var.additional_ca_certificate_paths : name => file(pathexpand(path))
  }

  workloads = {
    for w in local.cfg.onprem_workloads : w => {
      policy_name = try(local.onprem_policies[w].name, null)
      policy_json = try(jsonencode({ Version = "2012-10-17", Statement = local.onprem_policies[w].statements }), null)
    }
  }
}
