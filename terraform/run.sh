#!/usr/bin/env bash
# Terraform root를 정해진 순서로 실행한다 (GPU-171).
#
#   순서: state → data → identity → vpc → eks   (destroy는 거꾸로, 기본은 eks · vpc만)
#
#   state     Terraform state 버킷 (계정마다 한 번)            state 키 <env>/bootstrap
#   data      체크포인트 · 모니터링 S3, 펜싱 DynamoDB (지우지 않음)
#   identity  Roles Anywhere trust anchor · 워크로드 역할      ← bootstrap/certs.sh의 CA 공개 인증서 필요
#   vpc       VPC · 서브넷 · NAT · S3/DynamoDB 엔드포인트 · VPN  ← customer_gateway_ip 필요
#   eks       EKS A/B(/C) · GPU 노드그룹 · 온프레 허브 등록       ← vpc state, 온프레 kubeconfig, SOCKS 프록시
#
# 계정 · 프로파일은 코드에 없다. 계정 ID는 실행할 때 aws sts로 읽고, state 버킷 이름
# <project>-<env>-tfstate-<account>-<region>과 backend 설정을 여기서 만든다.
#
# 사용:
#   terraform/run.sh plan                    # 전체 plan (state → … → eks)
#   terraform/run.sh apply vpc eks           # 고른 것만, 순서는 자동으로 맞춘다
#   terraform/run.sh apply eks --topology full --proxy
#   terraform/run.sh destroy                 # eks → vpc (data · identity · state는 이름을 줘야만)
#   terraform/run.sh output identity -- -json
#
# 옵션:
#   --topology test|full   eks의 deployment_profile (기본: eks/terraform.local.tfvars, 없으면 test)
#   --proxy                eks용 SOCKS 터널(ssh -D 1080 k8s-master1)을 열고 HTTPS_PROXY를 건다
#   --profile NAME         AWS 프로파일 (기본 devoops. 셸의 AWS_PROFILE은 무시한다)
#   -y, --yes              계정 확인과 Terraform 승인을 건너뛴다 (-auto-approve)
#   --                     뒤의 인자는 terraform 명령에 그대로 넘긴다
#
# 환경 변수 (기본값):
#   AWS_REGION=us-east-2  PROJECT=devoops  ENVIRONMENT=prod
#   CA_CERT=~/.devoops/rolesanywhere/prod/ca.pem   (identity의 ca_certificate_path)
#   ONPREM_KUBECONFIG=~/.kube/devoops-onprem.yaml   (eks 허브 등록)
#   TF_VAR_*                                       (그 밖의 변수)
#   <root>/terraform.local.tfvars가 있으면 자동으로 -var-file로 넘긴다 (git 무시 파일).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORDER="state data identity vpc eks"
DEFAULT_DESTROY="eks vpc"
PERSISTENT="state data identity"

PROFILE="devoops"   # 팀 공통 프로파일 이름. 셸의 AWS_PROFILE은 쓰지 않는다 (--profile로만 바꾼다)
export AWS_REGION="${AWS_REGION:-us-east-2}"
export TF_VAR_aws_region="$AWS_REGION"
PROJECT="${PROJECT:-devoops}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
export TF_VAR_project_name="$PROJECT" TF_VAR_environment="$ENVIRONMENT"
CA_CERT="${CA_CERT:-$HOME/.devoops/rolesanywhere/$ENVIRONMENT/ca.pem}"
ONPREM_KUBECONFIG="${ONPREM_KUBECONFIG:-$HOME/.kube/devoops-onprem.yaml}"
export TF_IN_AUTOMATION=1

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# state 키 이름. state root는 처음 이름(bootstrap)을 유지한다 (state/main.tf root_names와 같아야 함).
state_key() { case "$1" in state) echo bootstrap ;; *) echo "$1" ;; esac; }
in_list() { local x="$1"; shift; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }

# ---------- 인자 ----------
[ $# -ge 1 ] || usage 1
CMD="$1"; shift
case "$CMD" in init|plan|apply|destroy|validate|output) ;; -h|--help|help) usage 0 ;; *) die "알 수 없는 명령: $CMD (init|plan|apply|destroy|validate|output)" ;; esac

STACKS=() TOPOLOGY="" PROXY=0 YES=0 EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --topology) TOPOLOGY="${2:-}"; shift 2 ;;
    --topology=*) TOPOLOGY="${1#*=}"; shift ;;
    --proxy) PROXY=1; shift ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    -y|--yes) YES=1; shift ;;
    --) shift; EXTRA=("$@"); break ;;
    -*) die "알 수 없는 옵션: $1" ;;
    *) in_list "$1" $ORDER || die "알 수 없는 stack: $1 ($ORDER)"; STACKS+=("$1"); shift ;;
  esac
done
[ -n "$PROFILE" ] || die "--profile 값이 비었습니다"
export AWS_PROFILE="$PROFILE"
[ -z "$TOPOLOGY" ] || in_list "$TOPOLOGY" test full || die "--topology는 test 또는 full"

# 고른 stack을 실행 순서대로 정렬 (destroy는 역순)
selected=()
if [ ${#STACKS[@]} -eq 0 ]; then
  if [ "$CMD" = destroy ]; then read -r -a selected <<<"$DEFAULT_DESTROY"; else read -r -a selected <<<"$ORDER"; fi
else
  for s in $ORDER; do in_list "$s" "${STACKS[@]}" && selected+=("$s"); done
  if [ "$CMD" = destroy ]; then
    rev=(); for ((i=${#selected[@]}-1; i>=0; i--)); do rev+=("${selected[$i]}"); done; selected=("${rev[@]}")
  fi
fi

command -v terraform >/dev/null || die "terraform이 없습니다"

# validate는 backend · 자격 증명 없이 문법만 본다 (CI와 같음)
if [ "$CMD" = validate ]; then
  for s in "${selected[@]}"; do
    echo "======== $s (validate)"
    tf_dir="$ROOT_DIR/$s"
    terraform -chdir="$tf_dir" init -input=false -backend=false >/dev/null
    terraform -chdir="$tf_dir" validate
  done
  exit 0
fi

# ---------- 계정 확인 ----------
command -v aws >/dev/null || die "aws CLI가 없습니다"
if ! ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
  die "AWS 자격 증명이 없습니다 (프로파일 ${AWS_PROFILE}). 먼저: aws sso login --profile ${AWS_PROFILE}"
fi
CALLER="$(aws sts get-caller-identity --query Arn --output text)"
STATE_BUCKET="$PROJECT-$ENVIRONMENT-tfstate-$ACCOUNT-$AWS_REGION"

echo "== terraform $CMD: ${selected[*]}"
echo "   계정 $ACCOUNT · 리전 $AWS_REGION · 프로파일 $AWS_PROFILE"
echo "   호출자 $CALLER"
echo "   state  s3://$STATE_BUCKET/$ENVIRONMENT/<stack>/terraform.tfstate"

if [ "$CMD" = destroy ]; then
  for s in "${selected[@]}"; do
    in_list "$s" $PERSISTENT && echo "   주의: ${s}는 영속 자원이라 prevent_destroy가 걸려 있어 보통 실패합니다"
  done
fi
if { [ "$CMD" = apply ] || [ "$CMD" = destroy ]; } && [ "$YES" -eq 0 ]; then
  read -r -p "이 계정에 $CMD 할까요? 계정 ID를 입력하세요: " answer
  [ "$answer" = "$ACCOUNT" ] || die "취소했습니다"
fi

bucket_exists() { aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; }

# ---------- 프록시 (eks) ----------
TUNNEL_PID=""
cleanup() {
  [ -z "$TUNNEL_PID" ] || kill "$TUNNEL_PID" 2>/dev/null || true
  rm -f "$ROOT_DIR"/state/zz_local_backend_override.tf
}
trap cleanup EXIT
start_proxy() {
  if nc -z 127.0.0.1 1080 2>/dev/null; then
    echo "   SOCKS 1080 이미 열려 있음"
  else
    ssh -N -D 1080 -o ExitOnForwardFailure=yes k8s-master1 & TUNNEL_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do nc -z 127.0.0.1 1080 2>/dev/null && break; sleep 1; done
    nc -z 127.0.0.1 1080 2>/dev/null || die "SOCKS 터널을 열지 못했습니다 (ssh k8s-master1)"
    echo "   SOCKS 터널 열림 (ssh -D 1080 k8s-master1, pid $TUNNEL_PID)"
  fi
}

# ---------- 실행 ----------
tf() { local d="$1"; shift; terraform -chdir="$ROOT_DIR/$d" "$@"; }

init_stack() {
  local s="$1"
  tf "$s" init -input=false -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="key=$ENVIRONMENT/$(state_key "$s")/terraform.tfstate" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="encrypt=true" \
    -backend-config="use_lockfile=true" >/dev/null
}

stack_args() { # plan · apply · destroy에 붙일 -var / -var-file
  local s="$1"
  ARGS=()
  [ -f "$ROOT_DIR/$s/terraform.local.tfvars" ] && ARGS+=("-var-file=terraform.local.tfvars")
  case "$s" in
    identity)
      [ -n "${TF_VAR_ca_certificate_path:-}" ] || export TF_VAR_ca_certificate_path="$CA_CERT"
      [ -f "$TF_VAR_ca_certificate_path" ] || die "CA 공개 인증서가 없습니다: $TF_VAR_ca_certificate_path (bootstrap/certs.sh 참고, CA_CERT로 경로 지정)" ;;
    vpc)
      if [ -z "${TF_VAR_customer_gateway_ip:-}" ] && ! grep -qs '^customer_gateway_ip' "$ROOT_DIR/vpc/terraform.local.tfvars"; then
        die "온프레 공인 IP가 필요합니다: TF_VAR_customer_gateway_ip 또는 vpc/terraform.local.tfvars"
      fi ;;
    eks)
      [ -z "$TOPOLOGY" ] || ARGS+=("-var-file=topology-$TOPOLOGY.tfvars")
      [ -n "${TF_VAR_hub_registration:-}" ] || export TF_VAR_hub_registration="{ onprem_kubeconfig = \"$ONPREM_KUBECONFIG\" }"
      [ -f "$ONPREM_KUBECONFIG" ] \
        || die "온프레 kubeconfig가 없습니다: $ONPREM_KUBECONFIG (ONPREM_KUBECONFIG로 지정)" ;;
  esac
  return 0
}

# state 버킷이 아직 없을 때: 로컬 state로 버킷을 만든 뒤 그 버킷으로 state를 옮긴다.
bootstrap_state_bucket() {
  echo "-- state: 버킷 $STATE_BUCKET 없음 → 로컬 state로 생성 후 이전"
  printf 'terraform {\n  backend "local" {}\n}\n' > "$ROOT_DIR/state/zz_local_backend_override.tf"
  tf state init -input=false -reconfigure >/dev/null
  if [ "$CMD" = plan ]; then tf state plan -input=false "${EXTRA[@]+"${EXTRA[@]}"}"; return; fi
  local approve=(); [ "$YES" -eq 1 ] && approve=(-auto-approve)
  tf state apply -input=false "${approve[@]+"${approve[@]}"}" "${EXTRA[@]+"${EXTRA[@]}"}"
  rm -f "$ROOT_DIR/state/zz_local_backend_override.tf"
  tf state init -input=false -migrate-state -force-copy \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="key=$ENVIRONMENT/$(state_key state)/terraform.tfstate" \
    -backend-config="region=$AWS_REGION" -backend-config="encrypt=true" -backend-config="use_lockfile=true"
  rm -f "$ROOT_DIR/state/terraform.tfstate" "$ROOT_DIR/state/terraform.tfstate.backup"
  echo "-- state: 버킷 생성 · state 이전 완료"
}

for s in "${selected[@]}"; do
  echo
  echo "======== $s ($CMD)"
  if ! bucket_exists; then
    if [ "$s" = state ] && { [ "$CMD" = apply ] || [ "$CMD" = plan ]; }; then
      bootstrap_state_bucket; continue
    fi
    die "state 버킷 $STATE_BUCKET 이 없습니다. 먼저: terraform/run.sh apply state"
  fi
  [ "$s" = eks ] && [ "$PROXY" -eq 1 ] && { start_proxy; export HTTPS_PROXY=socks5://127.0.0.1:1080; }
  init_stack "$s"
  [ "$CMD" = init ] && { echo "   init 완료"; continue; }
  ARGS=(); [ "$CMD" = output ] || stack_args "$s"
  approve=(); { [ "$CMD" = apply ] || [ "$CMD" = destroy ]; } && [ "$YES" -eq 1 ] && approve=(-auto-approve)
  case "$CMD" in
    output) tf "$s" output "${EXTRA[@]+"${EXTRA[@]}"}" ;;
    *) tf "$s" "$CMD" -input=false "${ARGS[@]+"${ARGS[@]}"}" "${approve[@]+"${approve[@]}"}" "${EXTRA[@]+"${EXTRA[@]}"}" ;;
  esac
  [ "$s" = eks ] && unset HTTPS_PROXY
done
echo
echo "== 완료: $CMD ${selected[*]}"
