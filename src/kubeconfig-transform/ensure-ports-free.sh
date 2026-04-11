#!/usr/bin/env bash
set -euo pipefail

PORTS=("$@")
if [ ${#PORTS[@]} -eq 0 ]; then
  PORTS=(9000 9001)
fi

if ! command -v lsof >/dev/null 2>&1; then
  echo "ERROR: lsof not found; cannot check which process is using ports: ${PORTS[*]}" >&2
  exit 1
fi

kill_pids() {
  local pids=("$@")
  if [ ${#pids[@]} -eq 0 ]; then
    return 0
  fi

  echo "Sending SIGTERM to PID(s): ${pids[*]}" >&2
  kill -TERM "${pids[@]}" 2>/dev/null || true

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

  pids=()
  while IFS= read -r pid; do
    [ -n "$pid" ] && pids+=("$pid")
  done < <(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u)

  if [ ${#pids[@]} -eq 0 ]; then
    echo "OK: port $port is free" >&2
    continue
  fi

  echo "Port $port is in use by PID(s): ${pids[*]}" >&2
  lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true

  kill_pids "${pids[@]}"

  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ERROR: port $port is still in use after kill attempts" >&2
    exit 3
  fi

  echo "OK: freed port $port" >&2
done