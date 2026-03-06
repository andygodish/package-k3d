#!/usr/bin/env bash
set -euo pipefail

# Transform a kubeconfig that points at k3d's 0.0.0.0:<port> server into one
# that points at the host's LAN IP (e.g. 192.168.0.x) so remote kubectl can use it.
#
# Default behavior:
# - input:  ~/.kube/config
# - output: ./kubeconfig.lan.yaml (in current directory)
# - replace: https://0.0.0.0:6550 -> https://<detected-ip>:6550

PORT="6550"
IN_PATH="$HOME/.kube/config"
OUT_PATH="$(pwd)/kubeconfig.lan.yaml"
IP_OVERRIDE=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [--in PATH] [--out PATH] [--port PORT] [--ip IP]

Options:
  --in PATH     Input kubeconfig (default: ~/.kube/config)
  --out PATH    Output kubeconfig (default: ./kubeconfig.lan.yaml)
  --port PORT   Port to use (default: 6550)
  --ip IP       Override detected host IP

Notes:
  - This script performs a targeted substitution of:
      server: https://0.0.0.0:<port>
    to:
      server: https://<host-ip>:<port>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) IN_PATH="$2"; shift 2;;
    --out) OUT_PATH="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --ip) IP_OVERRIDE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ ! -f "$IN_PATH" ]]; then
  echo "Input kubeconfig not found: $IN_PATH" >&2
  exit 1
fi

get_host_ip_macos() {
  # Determine default route interface, then ask ipconfig for its IPv4.
  local iface
  iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
  if [[ -z "$iface" ]]; then
    return 1
  fi
  ipconfig getifaddr "$iface" 2>/dev/null || return 1
}

get_host_ip_linux() {
  # Source address used to reach the public internet.
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}

HOST_IP="$IP_OVERRIDE"
if [[ -z "$HOST_IP" ]]; then
  case "$(uname -s)" in
    Darwin) HOST_IP="$(get_host_ip_macos || true)";;
    Linux) HOST_IP="$(get_host_ip_linux || true)";;
    *) HOST_IP="";;
  esac
fi

if [[ -z "$HOST_IP" ]]; then
  echo "Could not auto-detect host IPv4. Provide --ip <addr>." >&2
  exit 1
fi

if ! [[ "$HOST_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Detected/Provided IP doesn't look like IPv4: $HOST_IP" >&2
  exit 1
fi

SEARCH="server: https://0.0.0.0:${PORT}"
REPLACE="server: https://${HOST_IP}:${PORT}"

# Ensure the target string exists somewhere so we don't silently create a broken config.
if ! grep -qF "$SEARCH" "$IN_PATH"; then
  echo "Did not find expected kubeconfig server entry: '$SEARCH'" >&2
  echo "Tip: inspect your kubeconfig clusters, or pass a different --port." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_PATH")"

# macOS sed requires -i '' for in-place; but we avoid in-place and write to OUT_PATH.
# Use a safe, literal substitution.
# Use a non-slash delimiter so URLs don't get parsed as regex modifiers.
perl -pe "s{\Q$SEARCH\E}{$REPLACE}g" "$IN_PATH" > "$OUT_PATH"

chmod 0600 "$OUT_PATH" 2>/dev/null || true

echo "Wrote transformed kubeconfig: $OUT_PATH"
echo "Replaced: $SEARCH"
echo "With:     $REPLACE"
