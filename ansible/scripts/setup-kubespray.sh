#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/.vendor/kubespray"
COMMIT=9751ea6f63244e433a7a6263d9ecf381e57bb8e9
mkdir -p "$ROOT/.vendor"
if [[ ! -d "$DEST" ]]; then
  git clone --depth 1 --branch v2.32.0 https://github.com/kubernetes-sigs/kubespray.git "$DEST"
fi
[[ "$(git -C "$DEST" rev-parse HEAD)" == "$COMMIT" ]] || { echo 'Unexpected Kubespray revision'; exit 1; }
[[ -z "$(git -C "$DEST" status --porcelain)" ]] || { echo 'Vendor checkout modified'; exit 1; }
PYTHON_BIN="${PYTHON_BIN:-python3}"
"$PYTHON_BIN" -c 'import sys; assert sys.version_info >= (3, 12), "Use Python 3.12+ for Ansible 12.3.0"'
"$PYTHON_BIN" -m venv "$ROOT/.venv"
"$ROOT/.venv/bin/python" -m pip install -r "$DEST/requirements.txt"
echo "Ready. Use scripts/run-cluster.sh --syntax-check first."
