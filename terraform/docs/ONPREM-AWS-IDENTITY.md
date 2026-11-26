# On-prem AWS identity — IAM Roles Anywhere

The Roles Anywhere trust anchor, IAM roles, profiles and EKS access entries were
deployed on 2026-11-06. Workload certificate distribution and authentication
tests are pending.

## Terraform roots

- prod/data: persistent storage.
- prod/identity: external CA trust anchor, four roles, four profiles, four inline
  permission policies. One profile/role per workload, 1-hour AWS credentials.
- prod/network: EKS and access entries for MultiKueue and the relocation executor.

When actual creation is authorized, identity must exist before network creates
these IAM-principal access entries. Data must exist before workloads run. There
is no apply automation in this change. Changes to account, region or resource
names must be synchronized between these roots.

## Certificate setup

macOS · Linux: `bootstrap/certs.sh` (기본 backend · mimir · loki · tempo, 60일, 이미 있는 인증서는 건너뜀,
`--renew`는 같은 키로 재발급, `--status`는 만료일). 기존 CA가 없으면 `--init-ca`를 명시해야 새 CA를 만든다.
CA는 여러 개를 믿을 수 있다 (11/16, GPU-173). `live/base/terraform.local.tfvars`:

```hcl
ca_certificate_path = "~/.devoops/rolesanywhere/legacy/ca.pem"     # primary: 처음 CA (박기현 PC). 바꾸면 기존 인증서가 끊긴다
additional_ca_certificate_paths = {
  v2 = "~/.devoops/rolesanywhere/prod/ca.pem"                      # 노찬경 PC CA → trust anchor devoops-prod-onprem-ca-v2
}
```

워크로드 역할은 모든 anchor를 믿는다. helper(sidecar)에는 **인증서를 발급한 CA의 anchor ARN**을 넘긴다
(`terraform/run.sh output base -- trust_anchor_arns`). tfvars에 `ca_certificate_path`가 없으면 run.sh가 `CA_CERT`(기본 `~/.devoops/rolesanywhere/prod/ca.pem`)를 넘긴다.

Windows: 아래 PowerShell 스크립트 (같은 PKI 디렉터리 구조).

`scripts/rolesanywhere/New-WorkloadCertificate.ps1` creates a dedicated external
CA outside the repo, under the current Windows user's `.devoops/rolesanywhere/prod`.
The directory ACL allows only the current user and SYSTEM. Its PEM private key
is unencrypted on disk and protected by this ACL; the workstation/user account is
therefore part of the trust boundary. Keep a separately secured CA backup and
define the issuance/rotation operator before runtime deployment. Never mount or
copy ca.key into any Pod. Terraform reads only the public ca.pem, so private keys
never enter Terraform configuration, plan or state.

The dedicated CA is valid for two years. No paid AWS Private CA resource is
defined. The CA generation script refuses silent replacement of existing CA or
workload identity files. Before using an existing CA, confirm its key pair and
validity. No leaf certificate was issued during initial plan preparation.

When deployment is ready, issue each workload's separate 60-day certificate
using PowerShell (the script does not create Kubernetes Secrets):

```powershell
./scripts/rolesanywhere/New-WorkloadCertificate.ps1 -Workload backend
./scripts/rolesanywhere/New-WorkloadCertificate.ps1 -Workload recovery
./scripts/rolesanywhere/New-WorkloadCertificate.ps1 -Workload relocator
./scripts/rolesanywhere/New-WorkloadCertificate.ps1 -Workload multikueue
```

Monitoring workloads also have separate certificates. For an explicitly selected
60-day validity period (also the default for all workloads):

```powershell
./scripts/rolesanywhere/New-WorkloadCertificate.ps1 -Workload mimir -ValidityDays 60
./scripts/rolesanywhere/New-WorkloadCertificate.ps1 -Workload loki -ValidityDays 60
./scripts/rolesanywhere/New-WorkloadCertificate.ps1 -Workload tempo -ValidityDays 60
```

The corresponding CNs are `devoops-prod-mimir`, `devoops-prod-loki`, and
`devoops-prod-tempo`. Transfer only each workload's client.pem/client.key through
an agreed secure channel such as SCP into a private directory; never send ca.key.
Verify the active AWS trust anchor matches the issuing CA before handoff.
Retrieve fresh role/profile/trust-anchor ARNs after any AWS recreation rather
than reusing identifiers from an old state backup. Monitoring object retention
is managed by Mimir/Loki/Tempo; do not add a blanket 30-day S3 object expiration.

Changing the default does not extend existing certificates. Issue a renewal
under the same CA in a separate secured directory, verify its chain, CN, key
match and dates, then roll it out to the consumer before retiring the old leaf.
Certificate lifetime is separate from the 1-hour AWS session duration and from
S3 retention. Keep existing 30-day backup/app retention settings unchanged.

For explicit renewal, prepare a new secured PkiDirectory containing a restored
copy of the same ca.key/ca.pem and issue new leaves there. Verify the new chain,
deploy leaf files atomically, restart/reload consumers as necessary and confirm
new sessions before retiring old leaves. Track expiration and certificate
revocation; neither renewal distribution nor CRL publication is automated here.
An expired leaf cannot obtain fresh AWS sessions. An existing session can remain
usable until its AWS expiration even after certificate revocation.

Each role's trust policy restricts SourceAccount, exact trust-anchor ARN and exact
certificate Subject CN `devoops-prod-<workload>`. Sharing the CA does not grant a
backend certificate the recovery or scheduler role. Private keys must be mounted
only into their own workload, read-only and with limited Secret/RBAC access.

## Workload mapping and permissions

| Workload | Reported namespace | IAM role suffix | Current permission scope |
| --- | --- | --- | --- |
| Backend | web | onprem-backend | S3 code/datasets uploads; fencing PutItem/UpdateItem |
| Recovery controller | recovery | onprem-recovery | fencing GetItem/UpdateItem |
| Relocation executor | scheduler | onprem-relocator | fencing GetItem/UpdateItem; S3 code/*/jobset.json read; DescribeCluster eks-a/b/c |
| MultiKueue | kueue-system | onprem-multikueue | DescribeCluster eks-a/b/c |

Exact Deployment and ServiceAccount names are not yet confirmed. No progress or
events table is assumed; no guessed EC2 action is allowed. Backend must send
attribute_not_exists(job_id) when creating the initial fencing item. Recovery
and relocation must use the agreed conditional updates; IAM alone does not
enforce these application conditions.

## Runtime configuration (after AWS creation)

Install a checksum-verified aws_signing_helper in each consumer image and a
supported AWS SDK/CLI. Use the `credential_process` command emitted by
prod/identity output workloads.<name> in a read-only AWS config file:

```ini
[profile onprem]
region = us-east-2
credential_process = <the workload-specific output command>
```

The command expects that workload's leaf certificate at
`/var/run/devoops-aws/client.pem` and private key at `client.key`. Mount this
config as a ConfigMap and only the corresponding leaf files as a Secret. Set
AWS_PROFILE=onprem, AWS_CONFIG_FILE to its mounted path and AWS_REGION=us-east-2;
do not inject static AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/AWS_SESSION_TOKEN.
The process provider obtains and refreshes temporary AWS credentials. Certificate
renewal is a separate operation, not performed by the signing helper.

First validate STS caller identity and a permitted test operation for each role;
verify the same certificate cannot assume a different workload role. Test fresh
credential retrieval after renewal and across a full session expiration period.
None of these runtime checks has been performed yet.

## EKS API authorization

network declares IAM access entries for:

- onprem-multikueue → Kubernetes group `devoops:multikueue`
- onprem-relocator → Kubernetes group `devoops:relocator`

These groups grant no Kubernetes operations until scoped Role/ClusterRole
bindings are installed by the Gitops repo. No cluster-admin policy is attached. IAM
DescribeCluster is discovery, not permission to create/delete Kubernetes objects.
There is currently one EKS cluster; do not reference three uncreated workers.

The consumer needs an EKS kubeconfig with renewable authentication (for example
an exec provider using aws eks get-token under the Roles Anywhere profile).
aws CLI and helper must exist where the kubeconfig exec process runs. A pasted
one-time token will expire. Validate MultiKueue's actual remote-client support,
image binaries, required Kubernetes RBAC and token refresh with the scheduler
owner before declaring this integration complete.

Network routing is independent: Roles Anywhere/STS require reachable HTTPS
endpoints; private EKS API traffic uses the VPN path and requires matching SG/
firewall rules. Certificates do not establish a VPN or change routing.

References:
- https://docs.aws.amazon.com/rolesanywhere/latest/userguide/trust-model.html
- https://docs.aws.amazon.com/rolesanywhere/latest/userguide/credential-helper.html
- https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html
