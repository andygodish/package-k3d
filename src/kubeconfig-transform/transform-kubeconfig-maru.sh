#!/usr/bin/env bash
set -euo pipefail

# Wrapper intended to be called from UDS Maru tasks (which run under /bin/sh).
# Keeps bash-y logic out of tasks YAML.

IN_PATH=""
OUT_PATH="./uds.dev"
IP=""
PORT=""

usage() {
  cat <<EOF
Usage: $0 [--in PATH] [--out PATH] [--ip IPv4] [--port PORT]

Defaults:
  --in   ./kubeconfig if present, else \$KUBECONFIG, else ~/.kube/config
  --out  ./uds.dev
  --ip   auto-detected (primary egress IPv4)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) IN_PATH="$2"; shift 2 ;;
    --out) OUT_PATH="$2"; shift 2 ;;
    --ip) IP="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$IP" ]]; then
  if command -v ip >/dev/null 2>&1; then
    IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  fi
  if [[ -z "$IP" ]] && command -v hostname >/dev/null 2>&1; then
    IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
fi

if [[ -z "$IP" ]]; then
  echo "ERROR: could not auto-detect LAN IP; pass --ip" >&2
  exit 1
fi

auto_in() {
  if [[ -f ./kubeconfig ]]; then
    echo "./kubeconfig"
  elif [[ -n "${KUBECONFIG:-}" ]]; then
    echo "$KUBECONFIG"
  else
    echo "$HOME/.kube/config"
  fi
}

if [[ -z "$IN_PATH" ]]; then
  IN_PATH="$(auto_in)"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/transform-kubeconfig.sh"

if [[ ! -f "$SCRIPT" ]]; then
  echo "Expected script not found: $SCRIPT" >&2
  exit 1
fi

ARGS=("--in" "$IN_PATH" "--out" "$OUT_PATH" "--ip" "$IP")
if [[ -n "$PORT" ]]; then
  ARGS+=("--port" "$PORT")
fi

bash "$SCRIPT" "${ARGS[@]}"

echo "Sanity check (best-effort):" >&2
KUBECONFIG="$OUT_PATH" uds zarf tools kubectl cluster-info || true

echo "Wrote: $OUT_PATH" >&2
