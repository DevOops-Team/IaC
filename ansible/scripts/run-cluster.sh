#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/.vendor/kubespray"
INV="$ROOT/inventory/onprem/hosts.yaml"
ANSIBLE="$ROOT/.venv/bin/ansible-playbook"
[[ -x "$ANSIBLE" && -f "$VENDOR/cluster.yml" ]] || { echo 'Run setup-kubespray.sh first'; exit 1; }
[[ "$(git -C "$VENDOR" rev-parse HEAD)" == 9751ea6f63244e433a7a6263d9ecf381e57bb8e9 ]] || exit 1
# Resolve project preflight roles even while running from the vendor directory.
export ANSIBLE_ROLES_PATH="$ROOT/roles:$VENDOR/roles"
# Read-only syntax check does not contact VMs.
if [[ "${1:-}" == --syntax-check ]]; then
  cd "$VENDOR"
  ANSIBLE_HOST_KEY_CHECKING=True "$ANSIBLE" -i "$INV" "$ROOT/playbooks/infra/preflight.yml" --syntax-check
  ANSIBLE_HOST_KEY_CHECKING=True "$ANSIBLE" -i "$INV" cluster.yml --syntax-check
  exit
fi
# Keep upstream roles/config resolution, but retain SSH host-key verification.
cd "$VENDOR"
export ANSIBLE_HOST_KEY_CHECKING=True
export ANSIBLE_SSH_ARGS='-o ControlMaster=auto -o ControlPersist=60s'
"$ANSIBLE" -i "$INV" "$ROOT/playbooks/infra/preflight.yml" --become "$@"
"$ANSIBLE" -i "$INV" cluster.yml --become "$@"
