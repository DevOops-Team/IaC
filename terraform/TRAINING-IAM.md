# Training Pod IAM — prod

2026-11-06: AWS storage and the EKS Pod Identity association are deployed.
Training workload rollout and runtime access checks are pending.

## Sources

- [Checkpoint contract v9](https://devoops-team.atlassian.net/wiki/spaces/GPUF/pages/9699330)
- [JobSet template v6](https://devoops-team.atlassian.net/wiki/spaces/GPUF/pages/12222466)
- [ADR-12 v3](https://devoops-team.atlassian.net/wiki/spaces/GPUF/pages/12386320)
- Jira GPU-59 and GPU-61 marked done on November 5.

## Ownership and connection

`environments/prod/data` owns persistent storage, independently of the EKS lifecycle.
`environments/prod/network` and `modules/eks` own the training role, inline permissions
and AWS Pod Identity association. Storage ARNs in the EKS module call match the data
root names; update both roots together if those names change. Planning does not
require storage to have been created. Storage must exist before running jobs.

Association: `devoops-prod-eks-a` / namespace `training` / ServiceAccount `trainer`
→ `devoops-prod-eks-a-trainer-role`. Session tags restrict the trust policy to that
cluster ARN, namespace and ServiceAccount. Do not disable association session tags.

This is a Pod-level credential boundary. Init containers, sidecars and main containers
share the role; they are not separate IAM identities.

Allowed operations:

- Read objects under `code/`, `datasets/`, `jobs/` in the prod checkpoint bucket.
- List only those prefixes; get the bucket region.
- Upload to `jobs/` including abort/list-parts for multipart uploads.
- GetItem and UpdateItem on the prod fencing table only.
- No object/version deletion, DynamoDB DeleteItem, PutItem, Scan or administrator policy.

IAM permits UpdateItem but does not enforce the application ConditionExpression:
generation, owner, recovery phase and monotonic approved_step checks must be implemented
by the agent/controller. Without a condition, UpdateItem can also create an item.
These permissions are shared across jobs using the same ServiceAccount; per-job
data isolation has not been implemented.

The data owner's review confirms that every Pod UpdateItem must include
`generation = my_generation`; a missing item must fail that application condition.
The backend creates the initial fencing item with PutItem and
`attribute_not_exists(job_id)`. The Pod role deliberately lacks PutItem.

Bucket encryption in prod/data is SSE-S3 (AES256), not SSE-KMS. No KMS permissions
are required for this configuration. Revisit key policy and scoped KMS permissions
if encryption changes to a customer-managed KMS key.

## Kubernetes handoff (not applied)

The `gpu-k8s` owner must manage this namespace and ServiceAccount through GitOps,
and the JobSet must use `serviceAccountName: trainer` in namespace `training`.
This is the exact required object definition, not an additional Terraform provider:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: training
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: trainer
  namespace: training
```

Pod Identity uses the AWS-side association, with no IRSA role annotation on the
ServiceAccount. Do not insert static access keys in JobSet env or Kubernetes Secrets.
Use a Pod Identity-capable SDK and its default credential provider chain; earlier
static credentials in that chain would override Pod Identity. The node role has
AmazonEKSWorkerNodePolicy, including eks-auth:AssumeRoleForPodIdentity, and the module
already installs the Pod Identity Agent. Internet egress currently uses NAT.

After AWS creation and GitOps rollout, verify from a Pod using this ServiceAccount:
STS caller identity should show the trainer role; download and upload a dedicated
test object in permitted prefixes and exercise the agent's conditional DynamoDB
updates with test job IDs. Also verify forbidden prefix writes/deletes are denied.
No live credential or S3/DynamoDB operation has been tested yet.

## Pending design confirmation

Sent to Hyunsoo Kim by authorized Slack DM:
https://devoops-kqb2184.slack.com/archives/D0CBNR5DFB6/p1793863527253399

- Progress reporter table schema (partition/sort keys, indexes) and actual APIs.
  No progress table or speculative progress permission has been added yet.
- Progress items must include GENERATION to distinguish earlier runs; exact attribute
  casing and key/API design need confirmation against the service implementation.
- Do not create the legacy devoops-job-events table pending the service owner's
  confirmation of its planned Kafka replacement.
- Confirm a single bucket with code/, datasets/, jobs/ versus multiple example
  buckets in the JobSet document; align CONFIG_URI/DATASET_URI/CKPT_BUCKET accordingly.
- On-prem backend/recovery-controller AWS authentication and API scope. EKS Pod
  Identity cannot directly authenticate these on-prem workloads. No static keys
  have been created or distributed.

The table/bucket protections do not replace a complete long-term backup strategy.
No automatic data expiry is configured. Runtime access is incomplete until these
pending contracts are resolved and AWS/Kubernetes resources are actually deployed.

## Data owner response incorporated

The data owner agrees to code/{job_id}/, datasets/{ds-id}/v{n}/ and
jobs/{job_id}/gen-NNNN/step-NNNNNNNN/. Removed obsolete data/ permissions.
ListBucket remains scoped to these three prefixes and their descendants (a bare
code/ match alone would not allow listing code/{job_id}/). Backend confirmation
of its write paths and the JobSet example-name updates remains pending.

On-prem candidate workloads: backend in web, recovery controller in recovery,
relocation executor in scheduler, MultiKueue in kueue-system. These are namespaces,
not verified ServiceAccount names. Authentication design must cover AWS service
APIs and EKS IAM access entries plus appropriately scoped Kubernetes authorization.
Do not grant every workload cluster administrator access. Roles Anywhere is only
a proposed option; certificate trust/issuance/rotation and credential delivery are
  not configured. No AWS permissions are requested by the data collector/watchdog.

Update: Roles Anywhere has now been selected for implementation preparation.
The identity Terraform root and network access entries are written and planned;
see [ONPREM-AWS-IDENTITY.md](ONPREM-AWS-IDENTITY.md). Runtime deployment,
certificate distribution, precise ServiceAccounts and Kubernetes RBAC remain pending.

Retention proposal is not yet an implementable lifecycle policy: S3 expiration
does not consult DynamoDB approved_gen/approved_step and cannot directly keep the
last N checkpoint directories. With versioning, current-version expiration may
only create delete markers. Define how approved checkpoints are excluded and
how obsolete versions are handled before adding any expiration rule.
