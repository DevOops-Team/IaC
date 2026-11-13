# Database backup identity (GPU-128 / ADR-31)

Agreed on 2026-11-13; target handoff date 2026-11-14. Workload: `db-backup`
on database VM `172.30.0.50`. The persistent checkpoint bucket is retained
when the network/EKS environment is removed.

## Write-only permission

Role `devoops-prod-onprem-db-backup` and Roles Anywhere profile
`devoops-prod-db-backup` use certificate Subject CN `devoops-prod-db-backup`.
The only S3 permission statement allows:

- `s3:PutObject`
- `s3:AbortMultipartUpload`
- `s3:ListMultipartUploadParts`

Resource: `arn:aws:s3:::devoops-prod-ckpt-354363695096-us-east-2/backups/db/*`.
There is no GetObject, ListBucket/ListBackupPrefix, DeleteObject, access to
checkpoint paths, or bucket administration permission. SSE-S3 is used, so this
change adds no KMS permissions. Use unique timestamped object keys for backups.

Restore downloads run on the data owner's Mac using administrator SSO profile
`devoops`, followed by `pg_restore` into local PostgreSQL 16 and row-count
comparison with the operational database. Record results in GPU-128. Real
incident restores also use administrator downloads into a replacement VM;
the database workload does not need read permission.

## Retention

The data root adds one lifecycle configuration to the checkpoint bucket, with
rules restricted to `backups/db/`: current-object expiration at 30 days,
noncurrent-version expiration 30 days after a version becomes noncurrent, and
expired delete-marker cleanup. No rule is added for `jobs/`, `code/`, or
`datasets/`. S3 lifecycle processing is asynchronous.

Because versioning is enabled, current-object expiration first creates a delete
marker; it does not immediately erase all prior versions. Noncurrent retention
has its own 30-day clock, so physical storage can remain beyond 30 days from
original upload. Lifecycle must remain the bucket's single Terraform-managed
configuration; future rules for other prefixes belong in the same resource.

## Certificate and application handoff

Keep the previously agreed certificate transfer procedure. This change does
not distribute credentials or alter that procedure. The existing issuance
script now accepts `-Workload db-backup`; do not replace the CA or silently
overwrite an existing leaf. Keep private keys outside Git and Terraform state.

After identity apply, obtain this workload's role/profile identifiers and
credential-process template from `workloads["db-backup"]`. Use the existing
Roles Anywhere signing-helper setup described in ONPREM-AWS-IDENTITY.md.
Issuing a certificate alone does not install or activate it on the VM.

## Deployment boundaries

Review data and identity plans separately before apply. The backup job and timer,
upload verification, certificate handoff, and restore exercise are separate from
the Terraform changes. Do not grant read permission as a workaround for a
write-only client's listing or download attempts.

### 2026-11-13 validation (not applied)

- Both roots pass fmt/validate; the certificate script passes syntax parsing.
- IAM custom-policy simulation: all 18 action/resource combinations match the
  contract (three allowed uploads on the backup prefix, fifteen implicit denies).
- Data plan: 1 add, 0 change, 0 destroy. No existing lifecycle configuration was
  found on the bucket at review time.
- Identity plan: 3 add, 3 change, 0 destroy. The additions are the backup role,
  profile and inline policy. The existing changes are outside this request:
  backend loses live-only S3 GetObject/ListBucket and progress-table reads;
  MultiKueue/relocator discovery expands from eks-a to eks-a/b/c.
- Do not apply the entire identity root until those existing differences are
  reconciled with their owners. In particular, this backup change must not
  silently remove backend permissions used by the current application.
