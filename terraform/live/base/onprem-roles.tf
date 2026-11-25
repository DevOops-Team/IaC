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
          # 잡 상세: code/<id>/config.json 읽기 · 제출 파일 미리보기, 업로드 manifest.json 크기 (Backend job.go, GPU-185).
          # 학습 완료 모델: jobs/<id>/gen-N/step-N/manifest.json과 그 파일 스트리밍 (Backend model.go, GPU-190).
          # 키는 manifest에 적힌 것만 읽으므로 jobs/ 나열(ListBucket)은 주지 않는다
          Sid      = "ReadSubmission"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = ["${local.checkpoint_arn}/code/*", "${local.checkpoint_arn}/datasets/*", "${local.checkpoint_arn}/jobs/*"]
        },
        {
          # 끝난 학습 삭제 (Backend DELETE /api/jobs/{id}, GPU-196): 체크포인트 · 최종 모델 · 제출 · 업로드를
          # 버전과 삭제 표시까지 영구 삭제 (버킷 버전 관리 켜짐). backups/ 등 다른 접두어는 못 지운다
          Sid      = "DeleteFinishedJob"
          Effect   = "Allow"
          Action   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
          Resource = ["${local.checkpoint_arn}/code/*", "${local.checkpoint_arn}/datasets/*", "${local.checkpoint_arn}/jobs/*"]
        },
        {
          # 삭제할 버전 나열: 같은 세 접두어만
          Sid       = "ListFinishedJobVersions"
          Effect    = "Allow"
          Action    = "s3:ListBucketVersions"
          Resource  = local.checkpoint_arn
          Condition = { StringLike = { "s3:prefix" = ["code/*", "datasets/*", "jobs/*"] } }
        },
        {
          # 파일 목록: code/<id>/ 아래만 나열 (Backend Files). 다른 접두어(jobs/ · backups/)는 못 본다.
          # datasets/*: 브라우저 직접 업로드 확인(GPU-278). ListBucket이 없으면 없는 키의 HeadObject가 404가 아니라 403이라
          # "아직 올라가지 않음"과 권한 오류를 가를 수 없다
          Sid       = "ListSubmission"
          Effect    = "Allow"
          Action    = "s3:ListBucket"
          Resource  = local.checkpoint_arn
          Condition = { StringLike = { "s3:prefix" = ["code/*", "datasets/*"] } }
        },
        {
          # 첫 항목 생성(PutItem) + 사용자 다시 시작의 세대 +1 조건부 갱신(UpdateItem, GPU-240)
          Sid      = "CreateAndReadInitialFencing"
          Effect   = "Allow"
          Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
          Resource = local.fencing_arn
        },
      ]
    }
    recovery = {
      name = "recovery-data-access"
      statements = [
        {
          # ADR-50 / GPU-272: 복구 컨트롤러가 제출 원본을 읽고 검증해 RR spec에 전달한다.
          Sid      = "ReadRecoverySubmission"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "${local.checkpoint_arn}/code/*"
        },
        {
          # Scan: 하트비트 경과 지표가 펜싱 테이블 전체를 읽는다 (ADR-44, GPU-242)
          Sid      = "ManageRecoveryState"
          Effect   = "Allow"
          Action   = ["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:Scan"]
          Resource = local.fencing_arn
        },
        {
          Sid      = "ManageRecoveryTable"
          Effect   = "Allow"
          Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Scan"]
          Resource = module.recovery.arn
        },
      ]
    }
    relocator = {
      name = "relocator-data-access"
      statements = [
        # ADR-50 / GPU-272: RR spec 입력 · status 출력만 사용한다. AWS 데이터 권한은 recovery에 둔다.
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
