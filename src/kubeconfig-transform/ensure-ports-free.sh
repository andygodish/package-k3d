#!/usr/bin/env bash
set -euo pipefail

# Ensures local TCP ports are free before starting kubectl port-forward.
# Default ports used by MinIO tasks in this repo: 9000 (API) and 9001 (console).
#
# Usage:
#   ./tasks/scripts/ensure-port-forward-ports-free.sh            # checks 9000 + 9001
#   ./tasks/scripts/ensure-port-forward-ports-free.sh 9001       # checks 9001 only
#   ./tasks/scripts/ensure-port-forward-ports-free.sh 9000 9001  # checks both explicitly
#
# Behavior:
# - If a port is in use by a LISTENing process, we attempt a graceful stop (SIGTERM),
#   wait briefly, then SIGKILL if needed.

PORTS=("${@:-9000 9001}")

if ! command -v lsof >/dev/null 2>&1; then
  echo "ERROR: lsof not found; cannot check which process is using ports: ${PORTS[*]}" >&2
  exit 1
fi

kill_pids() {
  local pids=("$@")
  if [ ${#pids[@]} -eq 0 ]; then
    return 0
  fi

  # Graceful first
  echo "Sending SIGTERM to PID(s): ${pids[*]}" >&2
  kill -TERM "${pids[@]}" 2>/dev/null || true

  # Wait up to ~2s
  for _ in $(seq 1 20); do
    local still=()
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        still+=("$pid")
      fi
    done
    if [ ${#still[@]} -eq 0 ]; then
      return 0
    fi
    sleep 0.1
  done

  echo "PID(s) still alive; sending SIGKILL: ${pids[*]}" >&2
  kill -KILL "${pids[@]}" 2>/dev/null || true
}

for port in "${PORTS[@]}"; do
  if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid port: $port" >&2
    exit 2
  fi

  # Restrict to LISTEN sockets. -t outputs pids only.
  mapfile -t pids < <(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u)

  if [ ${#pids[@]} -eq 0 ]; then
    echo "OK: port $port is free" >&2
    continue
  fi

  echo "Port $port is in use by PID(s): ${pids[*]}" >&2
  # Provide a tiny bit of context for logs
  lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true

  kill_pids "${pids[@]}"

  # Verify
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ERROR: port $port is still in use after kill attempts" >&2
    exit 3
  fi

  echo "OK: freed port $port" >&2

done
