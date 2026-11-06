# Terraform state backend — prod

The state bucket and all four remote backends were initialized on 2026-11-06.
The prod foundation is deployed with one EKS CPU node.

## Layout

Dedicated bucket: `devoops-prod-tfstate-354363695096-us-east-2`.
This is not the training/checkpoint bucket.

| Root | State key |
| --- | --- |
| bootstrap | prod/bootstrap/terraform.tfstate |
| data | prod/data/terraform.tfstate |
| identity | prod/identity/terraform.tfstate |
| network | prod/network/terraform.tfstate |

Terraform 1.17 uses S3 native locking (`use_lockfile = true`). Each root has its
own `.tflock` object. No DynamoDB locking table is created; DynamoDB-based backend
locking is deprecated. These locks do not coordinate operations across different
roots, so honor deployment order and avoid simultaneous cross-root changes.
Use the default workspace; distinct roots already separate the states.

Bucket controls: versioning, SSE-S3/AES256, HTTPS-only policy, Block Public Access,
BucketOwnerEnforced, force_destroy=false and prevent_destroy. The bucket policy
denies DeleteObject/DeleteObjectVersion for the four state keys but deliberately
allows lock-file deletion when the caller has permission. No expiration rule is
defined. SSO AdministratorAccess can still change the policy/versioning settings;
this is protection against mistakes, not an immutable backup.

Versioned state and S3 requests incur standard S3 charges after creation. No
paid KMS key or DynamoDB locking resource is added. Saved states/plans can contain
VPN pre-shared keys or other sensitive data; never grant application roles access
to this bucket, upload state to Git, or share saved plan files as ordinary logs.

## Backend configuration

All four prod roots use an active `backend.tf`. Backend settings live under
`terraform/backends/prod/*.s3.tfbackend` and contain no secret credentials. A backend
authenticates independently from the AWS provider: both use profile devoops and
account allowlist 354363695096. The CLI's SSO login must be valid for both.

The bootstrap root exports a minimal backend-access policy for future SSO/CI
permission sets. It is a reference, not automatically attached, and contains no
AWS deployment permissions. It permits Get/Put state and Get/Put/Delete lock
objects. The currently used SSO AdministratorAccess already includes those actions.

## Initial deployment sequence

These steps document the initial bootstrap. For a fresh checkout of the existing
prod deployment, initialize the active backend with its matching configuration
file. Generate a fresh plan after backend or permission changes.

1. Sign into account 354363695096 with profile devoops; verify STS caller identity.
2. In prod/bootstrap, init/validate/plan locally, then create only its six state
   bucket resources. The initial bootstrap state will be local.
3. Confirm bucket ownership, region, versioning, encryption, policy and public
   access controls before storing any project state.
4. Back up any existing local states and record their resource lists in secured
   storage outside Git. Do not remove local states or overwrite a remote key that
   already holds resources from another root.
5. Activate the backend and migrate bootstrap first. Then configure data, identity
   and network using their separate keys, checking every state list after init.
6. Generate fresh plans and deploy data and identity before network. Identity
   roles must exist before network creates their EKS access entries. Do not issue
   leaf certificates too early; runtime credential rollout follows AWS creation.
7. Configure pfSense from the newly created VPN's values, deploy the agreed
   Kubernetes RBAC/workload credentials and verify permissions/traffic. GPU is
   deliberately deferred.

For step 5, these are the CMD commands for bootstrap after bucket creation:

```cmd
cd /d C:\Users\USER\Desktop\IaC\terraform\environments\prod\bootstrap
copy backend.tf.example backend.tf
terraform init -migrate-state -backend-config="../../../backends/prod/bootstrap.s3.tfbackend"
terraform state list
terraform plan
```

Use the matching root/config for the other three, for example network:

```cmd
cd /d C:\Users\USER\Desktop\IaC\terraform\environments\prod\network
copy backend.tf.example backend.tf
terraform init -migrate-state -backend-config="../../../backends/prod/network.s3.tfbackend"
terraform state list
terraform plan -var-file="terraform.local.tfvars"
```

Identity also needs `-var-file="terraform.local.tfvars"`; data needs no variable
file. For roots with no resources yet, there may be no local state to copy.
Do not use `-force-copy`, `state push -force`, delete a lock, or use `init
-reconfigure` as a substitute for reviewing a real state migration. Once S3 is
active, subsequent normal init commands may use the matching backend config;
new checkouts must receive it explicitly. backend.tf becomes tracked source once
activated; keep inactive examples until the initial bootstrap transition occurs.

## Verification after activation

- State lists and resource identifiers match before/after migration.
- S3 contains the expected state key and version history for each applied root.
- A legitimate plan obtains and releases its own `.tflock`; test concurrent
  access only under controlled conditions, never by manually deleting an active lock.
- A fresh checkout with the same authorized SSO identity reads the same state.
- Recovery from an older S3 state version requires explicit review against real
  AWS resources; restoring old state is not the same as rolling infrastructure back.

References:
- https://developer.hashicorp.com/terraform/language/backend/s3
- https://developer.hashicorp.com/terraform/cli/commands/init
- https://aws.amazon.com/s3/pricing/
