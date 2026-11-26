#!/usr/bin/env bash
# Terraform root를 정해진 순서로 실행한다 (GPU-171).
#
#   순서: state → base → eks          (destroy는 기본 eks만)
#
#   state       terraform/state       Terraform state 버킷 (계정마다 한 번)             state 키 <env>/bootstrap
#   base        terraform/live/base   S3 · DynamoDB · Roles Anywhere · VPC(network)      ← CA 공개 인증서, 온프레 공인 IP
#   eks         terraform/live/eks    EKS 클러스터 · GPU 노드그룹 · 온프레 허브 등록        ← base, 온프레 kubeconfig, SOCKS 프록시
#
# EKS OFF 첫 단계: destroy eks는 지우기 전에 K8s 레포 scheduling/ops/eks_gate.py fence <eks-x>로 펜싱한다.
#   워커가 살아 있을 때 펜싱해야 디스패처가 워커 식별값을 남기고, 다시 apply하면 라벨을 스스로 푼다.
#   남은 잡이 있거나 펜싱에 실패하면 destroy를 멈춘다 (--skip-fence로 건너뜀, 그러면 자동 해제가 안 된다).
# EKS ON 마지막 단계: apply eks 뒤 펜싱 라벨(devoops/fenced)이 남아 있으면 안내가 나온다.
#   K8s 레포 scheduling/ops/eks_gate.py on-check <eks-x> --unfence 로 확인 뒤 지운다 (지우기 전엔 잡이 안 감)
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
#   --skip-fence           destroy eks 전 펜싱을 건너뛴다 (온프레에 못 닿을 때만. ON 때 수동 해제 필요)
#   --                     뒤의 인자는 terraform 명령에 그대로 넘긴다
#
# 환경 변수 (기본값):
#   ENVIRONMENT=prod                              (config/<ENVIRONMENT>.yaml)
#   CA_CERT=~/.devoops/rolesanywhere/<env>/ca.pem  (base의 Roles Anywhere CA 공개 인증서)
#   ONPREM_KUBECONFIG=~/.kube/devoops-onprem.yaml   (eks 허브 등록, destroy 전 펜싱. current-context가 관리 클러스터)
#   K8S_REPO=<이 레포 옆>/K8s                        (destroy 전 펜싱에 쓰는 eks_gate.py가 있는 K8s 레포)
#   PYTHON=python3                                 (kubernetes 패키지가 설치된 파이썬)
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
K8S_REPO="${K8S_REPO:-$TF_DIR/../../K8s}"
PYTHON="${PYTHON:-python3}"
export TF_IN_AUTOMATION=1 TF_VAR_environment="$ENVIRONMENT"
# provider를 root마다 받지 않고 한 곳에 받아 링크로 쓴다 (aws provider 하나가 약 700MB)
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
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

STACKS=() TOPOLOGY="" PROXY=0 YES=0 SKIP_FENCE=0 EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --topology) TOPOLOGY="${2:-}"; shift 2 ;;
    --topology=*) TOPOLOGY="${1#*=}"; shift ;;
    --proxy) PROXY=1; shift ;;
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    -y|--yes) YES=1; shift ;;
    --skip-fence) SKIP_FENCE=1; shift ;;
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
      # primary CA 경로는 live/base/terraform.local.tfvars가 있으면 그 값을 쓴다 (CA를 추가 · 교체한 PC는 여기에 적는다)
      if ! grep -qs '^ca_certificate_path' "$TF_DIR/live/base/terraform.local.tfvars"; then
        [ -n "${TF_VAR_ca_certificate_path:-}" ] || export TF_VAR_ca_certificate_path="$CA_CERT"
        [ -f "$TF_VAR_ca_certificate_path" ] || die "CA 공개 인증서가 없습니다: ${TF_VAR_ca_certificate_path} (bootstrap/certs.sh 참고, CA_CERT로 경로 지정)"
      fi
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

eks_aliases() { tf eks output -json cluster_names 2>/dev/null | grep -oE '"[a-z0-9-]+" *:' | tr -d '": ' || true; }

# eks destroy 전: 워커가 아직 살아 있을 때 eks_gate fence로 펜싱한다 (GPU-277).
# fence는 라벨과 devoops/fenced-by=eks-off 표시를 붙이고 디스패처 ACK를 기다린다. 그 루프에서 디스패처가 지금 워커
# 식별값(devoops/fenced-worker-id)을 남기므로, 다시 apply하면 디스패처가 라벨을 스스로 푼다. EKS를 지운 뒤에
# 펜싱하면 식별값을 남길 수 없어 자동 해제가 되지 않는다. 그래서 펜싱 · OFF 확인이 실패하면 destroy를 멈춘다.
# 펜싱 로직(표시 · resourceVersion · ACK · 남은 잡 확인)은 eks_gate.py 하나에만 둔다.
eks_fence_before_destroy() {
  local aliases a gate ctx rc failed=()
  if [ "$SKIP_FENCE" -eq 1 ]; then
    echo "   주의: --skip-fence: 펜싱 없이 지웁니다. ON 뒤 자동 해제가 안 되고, 라벨이 없으면 지우는 동안 잡이 갈 수 있습니다"
    return 0
  fi
  aliases="$(eks_aliases)"
  if [ -z "$aliases" ]; then
    echo "   (펜싱 건너뜀: eks output cluster_names 없음. 이미 지워졌거나 apply 전)"
    return 0
  fi
  gate="$K8S_REPO/scheduling/ops/eks_gate.py"
  local skip="펜싱 없이 지우려면 --skip-fence"
  [ -f "$gate" ] || die "eks_gate.py가 없습니다: ${gate} (K8S_REPO로 K8s 레포 경로 지정, ${skip})"
  # 표시를 안 붙이는 옛 fence는 라벨만 남겨 자동 해제가 안 된다 (2026-11-26 재발). K8s main v2.6.0 이상이 필요하다
  grep -q 'mark_eks_off' "$gate" \
    || die "eks_gate.py가 옛 버전입니다 (eks-off 표시 없음): ${gate}. K8s 레포를 main v2.6.0 이상으로 받은 뒤 다시 실행 (${skip})"
  command -v kubectl >/dev/null || die "kubectl이 없습니다 (${skip})"
  "$PYTHON" -c 'import kubernetes' 2>/dev/null || die "${PYTHON}에 kubernetes 패키지가 없습니다 (PYTHON으로 지정, ${skip})"
  ctx="$(kubectl --kubeconfig "$ONPREM_KUBECONFIG" config current-context 2>/dev/null)" \
    || die "온프레 kubeconfig에 current-context가 없습니다: ${ONPREM_KUBECONFIG} (${skip})"
  echo "-- 펜싱: destroy 전에 eks_gate fence (관리 context ${ctx})"
  for a in $aliases; do
    echo "   == eks-${a}"
    rc=0
    # 온프레 API는 SOCKS 프록시 없이 닿는다 (eks_fence_notice와 같음)
    env -u HTTPS_PROXY KUBECONFIG="$ONPREM_KUBECONFIG" "$PYTHON" "$gate" --manager-context "$ctx" fence "eks-$a" || rc=$?
    [ "$rc" -eq 0 ] || failed+=("eks-${a}(종료 코드 ${rc})")
  done
  [ ${#failed[@]} -eq 0 ] || die "펜싱 · OFF 확인 실패: ${failed[*]}. 붙인 라벨은 남아 있습니다.
   남은 잡 · 처리 중 RR을 정리한 뒤 다시 실행합니다 (종료 코드 1: 남은 잡, 2: 접속 오류 · 디스패처 ACK 없음).
   OFF를 취소하려면 kubectl --kubeconfig ${ONPREM_KUBECONFIG} label multikueuecluster <eks-x> devoops/fenced- (${skip})"
}

# eks apply 뒤: OFF 때 붙인 펜싱 라벨(devoops/fenced=true)이 남은 MultiKueueCluster를 알린다 (GPU-238).
# 라벨이 남아 있으면 디스패처가 그 클러스터로 잡을 보내지 않는다. 준비 확인 게이트를 건너뛰지 않도록
# 여기서 지우지 않고 eks_gate on-check --unfence를 안내한다. 조회 실패는 경고만 하고 apply 결과는 그대로 둔다.
eks_fence_notice() {
  local aliases fenced=() a label
  command -v kubectl >/dev/null || { echo "   (펜싱 확인 건너뜀: kubectl 없음)"; return 0; }
  aliases="$(eks_aliases)"
  [ -n "$aliases" ] || return 0
  for a in $aliases; do
    if ! label="$(kubectl --kubeconfig "$ONPREM_KUBECONFIG" --request-timeout=15s get multikueuecluster "eks-$a" \
                  -o jsonpath='{.metadata.labels.devoops/fenced}' 2>/dev/null)"; then
      echo "   경고: 온프레 MultiKueueCluster eks-${a}를 조회하지 못해 펜싱 여부를 확인 못 함"
      continue
    fi
    [ "$label" = true ] && fenced+=("eks-$a")
  done
  [ ${#fenced[@]} -gt 0 ] || return 0
  echo
  echo "== 다음 단계: 펜싱 해제 (${fenced[*]})"
  echo "   ${fenced[*]}에 devoops/fenced=true가 남아 있어 디스패처가 새 잡을 보내지 않습니다."
  echo "   준비 상태를 확인하고 라벨을 지우려면 (K8s 레포, scheduling/ops/README.md):"
  for a in "${fenced[@]}"; do
    echo "     python scheduling/ops/eks_gate.py --manager-context <관리-context> on-check ${a} --worker-context <${a}-context> --unfence"
  done
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
  if [ "$s" = eks ] && [ "$CMD" = destroy ]; then eks_fence_before_destroy; fi
  case "$CMD" in
    output) tf "$s" output "${EXTRA[@]+"${EXTRA[@]}"}" ;;
    *) tf "$s" "$CMD" -input=false "${ARGS[@]+"${ARGS[@]}"}" "${approve[@]+"${approve[@]}"}" "${EXTRA[@]+"${EXTRA[@]}"}" ;;
  esac
  [ "$s" = eks ] && unset HTTPS_PROXY
  if [ "$s" = eks ] && [ "$CMD" = apply ]; then eks_fence_notice; fi
done
echo
echo "== 완료: ${CMD} ${selected[*]}"
