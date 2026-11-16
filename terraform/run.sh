#!/usr/bin/env bash
# Terraform root를 정해진 순서로 실행한다 (GPU-171).
#
#   순서: state → base → eks          (destroy는 기본 eks만)
#
#   state       terraform/state       Terraform state 버킷 (계정마다 한 번)             state 키 <env>/bootstrap
#   base        terraform/live/base   S3 · DynamoDB · Roles Anywhere · VPC(network)      ← CA 공개 인증서, 온프레 공인 IP
#   eks         terraform/live/eks    EKS 클러스터 · GPU 노드그룹 · 온프레 허브 등록        ← base, 온프레 kubeconfig, SOCKS 프록시
#
# 사람이 고치는 값은 terraform/config/<env>.yaml 한 곳이다. 계정 · 프로파일은 코드에 없다:
# 계정 ID는 실행할 때 aws sts로 읽고, state 버킷 <project>-<env>-tfstate-<account>-<region>과
# backend 설정을 여기서 만든다.
#
# 사용:
#   terraform/run.sh plan                        # 전체 plan (state → base → eks)
#   terraform/run.sh apply base                  # 고른 것만, 순서는 자동으로 맞춘다
#   terraform/run.sh apply eks --topology full --proxy
#   terraform/run.sh destroy                     # eks만 (VPC · NAT · VPN은 config network.enabled: false로 base apply)
#   terraform/run.sh output base -- workloads
#   terraform/run.sh validate                    # 자격 증명 없이 문법 검사 (CI와 같음)
#
# 옵션:
#   --topology NAME        config eks.topologies의 키 (test | full). 없으면 config eks.topology
#   --proxy                eks용 SOCKS 터널(ssh -D 1080 k8s-master1)을 열고 HTTPS_PROXY를 건다
#   --profile NAME         AWS 프로파일 (기본 devoops. 셸의 AWS_PROFILE은 무시한다)
#   -y, --yes              계정 확인과 Terraform 승인을 건너뛴다 (-auto-approve)
#   --                     뒤의 인자는 terraform 명령에 그대로 넘긴다
#
# 환경 변수 (기본값):
#   ENVIRONMENT=prod                              (config/<ENVIRONMENT>.yaml)
#   CA_CERT=~/.devoops/rolesanywhere/<env>/ca.pem  (base의 Roles Anywhere CA 공개 인증서)
#   ONPREM_KUBECONFIG=~/.kube/devoops-onprem.yaml   (eks 허브 등록)
#   TF_PLUGIN_CACHE_DIR=~/.terraform.d/plugin-cache (provider 공유 캐시)
#   TF_VAR_*                                       (그 밖의 변수)
#   <root>/terraform.local.tfvars가 있으면 자동으로 -var-file로 넘긴다 (Git 제외, 예: customer_gateway_ip).
set -euo pipefail

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORDER="state base eks"
PERSISTENT="state base"

ENVIRONMENT="${ENVIRONMENT:-prod}"
CONFIG="$TF_DIR/config/$ENVIRONMENT.yaml"
PROFILE="devoops"   # 팀 공통 프로파일 이름. 셸의 AWS_PROFILE은 쓰지 않는다 (--profile로만 바꾼다)
CA_CERT="${CA_CERT:-$HOME/.devoops/rolesanywhere/$ENVIRONMENT/ca.pem}"
ONPREM_KUBECONFIG="${ONPREM_KUBECONFIG:-$HOME/.kube/devoops-onprem.yaml}"
export TF_IN_AUTOMATION=1 TF_VAR_environment="$ENVIRONMENT"
# provider를 root마다 받지 않고 한 곳에 받아 링크로 쓴다 (aws provider 하나가 약 700MB)
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
in_list() { local x="$1"; shift; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }
stack_dir() { case "$1" in state) echo state ;; *) echo "live/$1" ;; esac; }
# state 키 이름. state root는 처음 이름(bootstrap)을 유지한다 (state/main.tf root_names와 같아야 함).
state_key() { case "$1" in state) echo bootstrap ;; *) echo "$1" ;; esac; }
# config의 최상위 값 (project · environment · region)
cfg_top() { awk -F': *' -v k="$1" '$1==k {sub(/ *#.*/,"",$2); gsub(/[" ]/,"",$2); print $2; exit}' "$CONFIG"; }
# config network.enabled
network_enabled() { awk '/^network:/{n=1;next} n && /^[^ #]/{n=0} n && $1=="enabled:"{print $2; exit}' "$CONFIG"; }

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
[ -f "$CONFIG" ] || die "config가 없습니다: $CONFIG"
[ -n "$PROFILE" ] || die "--profile 값이 비었습니다"
export AWS_PROFILE="$PROFILE"

# 고른 stack을 실행 순서대로 (destroy는 역순, 기본은 eks만)
selected=()
if [ ${#STACKS[@]} -eq 0 ]; then
  if [ "$CMD" = destroy ]; then selected=(eks); else read -r -a selected <<<"$ORDER"; fi
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
    echo "======== ${s} (validate)"
    terraform -chdir="$TF_DIR/$(stack_dir "$s")" init -input=false -backend=false >/dev/null
    terraform -chdir="$TF_DIR/$(stack_dir "$s")" validate
  done
  exit 0
fi

# ---------- 계정 확인 ----------
command -v aws >/dev/null || die "aws CLI가 없습니다"
if ! ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
  die "AWS 자격 증명이 없습니다 (프로파일 ${AWS_PROFILE}). 먼저: aws sso login --profile ${AWS_PROFILE}"
fi
CALLER="$(aws sts get-caller-identity --query Arn --output text)"
PROJECT="$(cfg_top project)"; CFG_ENV="$(cfg_top environment)"; REGION="$(cfg_top region)"
[ -n "$PROJECT" ] && [ -n "$CFG_ENV" ] && [ -n "$REGION" ] || die "config에 project · environment · region이 필요합니다"
export AWS_REGION="$REGION"
STATE_BUCKET="$PROJECT-$CFG_ENV-tfstate-$ACCOUNT-$REGION"

echo "== terraform ${CMD}: ${selected[*]}"
echo "   계정 ${ACCOUNT} · 리전 ${REGION} · 프로파일 ${AWS_PROFILE} · config ${ENVIRONMENT}.yaml"
echo "   호출자 ${CALLER}"
echo "   state  s3://${STATE_BUCKET}/${CFG_ENV}/<stack>/terraform.tfstate"
if [ "$CMD" = destroy ]; then
  for s in "${selected[@]}"; do
    in_list "$s" $PERSISTENT && echo "   주의: ${s}는 영속 자원(prevent_destroy)이 있어 destroy가 실패합니다. 네트워크만 끄려면 config network.enabled: false로 base apply"
  done
fi
if { [ "$CMD" = apply ] || [ "$CMD" = destroy ]; } && [ "$YES" -eq 0 ]; then
  read -r -p "이 계정에 ${CMD} 할까요? 계정 ID를 입력하세요: " answer
  [ "$answer" = "$ACCOUNT" ] || die "취소했습니다"
fi

bucket_exists() { aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; }

# ---------- 프록시 (eks) ----------
TUNNEL_PID=""
cleanup() {
  [ -z "$TUNNEL_PID" ] || kill "$TUNNEL_PID" 2>/dev/null || true
  rm -f "$TF_DIR"/state/zz_local_backend_override.tf
}
trap cleanup EXIT
start_proxy() {
  if nc -z 127.0.0.1 1080 2>/dev/null; then
    echo "   SOCKS 1080 이미 열려 있음"
  else
    ssh -N -D 1080 -o ExitOnForwardFailure=yes k8s-master1 & TUNNEL_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do nc -z 127.0.0.1 1080 2>/dev/null && break; sleep 1; done
    nc -z 127.0.0.1 1080 2>/dev/null || die "SOCKS 터널을 열지 못했습니다 (ssh k8s-master1)"
    echo "   SOCKS 터널 열림 (ssh -D 1080 k8s-master1, pid ${TUNNEL_PID})"
  fi
}

# ---------- 실행 ----------
tf() { local s="$1"; shift; terraform -chdir="$TF_DIR/$(stack_dir "$s")" "$@"; }
backend_args() {
  echo "-backend-config=bucket=$STATE_BUCKET"
  echo "-backend-config=key=$CFG_ENV/$(state_key "$1")/terraform.tfstate"
  echo "-backend-config=region=$REGION"
  echo "-backend-config=encrypt=true"
  echo "-backend-config=use_lockfile=true"
}
init_stack() {
  local args=(); while IFS= read -r a; do args+=("$a"); done < <(backend_args "$1")
  tf "$1" init -input=false -reconfigure "${args[@]}" >/dev/null
}

stack_args() { # plan · apply · destroy에 붙일 -var-file과 사전 검사
  local s="$1"
  ARGS=()
  [ -f "$TF_DIR/$(stack_dir "$s")/terraform.local.tfvars" ] && ARGS+=("-var-file=terraform.local.tfvars")
  case "$s" in
    base)
      [ -n "${TF_VAR_ca_certificate_path:-}" ] || export TF_VAR_ca_certificate_path="$CA_CERT"
      [ -f "$TF_VAR_ca_certificate_path" ] || die "CA 공개 인증서가 없습니다: ${TF_VAR_ca_certificate_path} (bootstrap/certs.sh 참고, CA_CERT로 경로 지정)"
      if [ "$(network_enabled)" = true ] && [ -z "${TF_VAR_customer_gateway_ip:-}" ] \
         && ! grep -qs '^customer_gateway_ip' "$TF_DIR/live/base/terraform.local.tfvars"; then
        die "network.enabled: true에는 온프레 공인 IP가 필요합니다: TF_VAR_customer_gateway_ip 또는 live/base/terraform.local.tfvars"
      fi ;;
    eks)
      [ -z "$TOPOLOGY" ] || ARGS+=("-var=deployment_profile=$TOPOLOGY")   # -var가 tfvars보다 우선
      [ -n "${TF_VAR_hub_registration:-}" ] || export TF_VAR_hub_registration="{ onprem_kubeconfig = \"$ONPREM_KUBECONFIG\" }"
      [ -f "$ONPREM_KUBECONFIG" ] || die "온프레 kubeconfig가 없습니다: ${ONPREM_KUBECONFIG} (ONPREM_KUBECONFIG로 지정)" ;;
  esac
  return 0
}

# state 버킷이 아직 없을 때: 로컬 state로 버킷을 만든 뒤 그 버킷으로 state를 옮긴다.
bootstrap_state_bucket() {
  echo "-- state: 버킷 ${STATE_BUCKET} 없음 → 로컬 state로 생성 후 이전"
  printf 'terraform {\n  backend "local" {}\n}\n' > "$TF_DIR/state/zz_local_backend_override.tf"
  tf state init -input=false -reconfigure >/dev/null
  if [ "$CMD" = plan ]; then tf state plan -input=false "${EXTRA[@]+"${EXTRA[@]}"}"; return; fi
  local approve=(); [ "$YES" -eq 1 ] && approve=(-auto-approve)
  tf state apply -input=false "${approve[@]+"${approve[@]}"}" "${EXTRA[@]+"${EXTRA[@]}"}"
  rm -f "$TF_DIR/state/zz_local_backend_override.tf"
  local args=(); while IFS= read -r a; do args+=("$a"); done < <(backend_args state)
  tf state init -input=false -migrate-state -force-copy "${args[@]}"
  rm -f "$TF_DIR/state/terraform.tfstate" "$TF_DIR/state/terraform.tfstate.backup"
  echo "-- state: 버킷 생성 · state 이전 완료"
}

for s in "${selected[@]}"; do
  echo
  echo "======== ${s} (${CMD})"
  if ! bucket_exists; then
    if [ "$s" = state ] && { [ "$CMD" = apply ] || [ "$CMD" = plan ]; }; then
      bootstrap_state_bucket; continue
    fi
    die "state 버킷 ${STATE_BUCKET}이 없습니다. 먼저: terraform/run.sh apply state"
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
echo "== 완료: ${CMD} ${selected[*]}"
