#!/usr/bin/env bash
set -euo pipefail

# Wrapper intended to be called from UDS Maru tasks (which run under /bin/sh).
# Keeps bash-specific argument handling out of tasks YAML.
#
# IP auto-detection is intentionally delegated to transform-kubeconfig.sh
# so there is a single implementation responsible for determining the
# appropriate LAN address.

IN_PATH=""
OUT_PATH="./uds-dev-config"
IP=""
PORT=""

usage() {
  cat <<EOF
Usage: $0 [--in PATH] [--out PATH] [--ip IPv4] [--port PORT]

Defaults:
  --in   ./kubeconfig if present, else \$KUBECONFIG, else ~/.kube/config
  --out  ./uds-dev-config
  --ip   auto-detected by transform-kubeconfig.sh
  --port use the port already present in the kubeconfig
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in)
      IN_PATH="$2"
      shift 2
      ;;
    --out)
      OUT_PATH="$2"
      shift 2
      ;;
    --ip)
      IP="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

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

ARGS=(
  "--in" "$IN_PATH"
  "--out" "$OUT_PATH"
)

# Only pass --ip when explicitly provided.
# Otherwise transform-kubeconfig.sh performs auto-detection.
if [[ -n "$IP" ]]; then
  ARGS+=("--ip" "$IP")
fi

# Only override the API server port when explicitly provided.
if [[ -n "$PORT" ]]; then
  ARGS+=("--port" "$PORT")
fi

bash "$SCRIPT" "${ARGS[@]}"

# The k3d API server certificate is generated for addresses known when the
# cluster is created and may not contain the LAN address used by this
# transformed kubeconfig. This is a development-only kubeconfig, so disable
# API server certificate verification while retaining client certificate
# authentication.
uds zarf tools kubectl config \
  --kubeconfig="$OUT_PATH" \
  set-cluster k3d-uds \
  --insecure-skip-tls-verify=true

echo "Wrote: $OUT_PATH" >&2