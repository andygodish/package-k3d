#!/usr/bin/env bash
set -euo pipefail

# Restore MinIO PVC by re-binding it to a static PV (hostPath) defined in kustomize/
#
# Flow:
#   1) scale down minio
#   2) delete pvc (and optional old restore PV)
#   3) apply kustomization (PV+PVC)
#   4) scale minio back up
#
# Assumptions:
# - You have kubectl context pointed at the target cluster.
# - MinIO is deployed as a Deployment named 'minio' in namespace uds-dev-stack.
# - kustomize/ defines the PV (pv-minio-restore) + PVC (minio).

# NS=uds-dev-stack MINIO_DEPLOY=minio SCALE_UP_REPLICAS=1 ./restore.sh

NS=${NS:-uds-dev-stack}
MINIO_DEPLOY=${MINIO_DEPLOY:-minio}

# Pick what to apply:
# - OVERLAY=base|test|prod (preferred)
# - or KUSTOMIZE_DIR=/path/to/kustomize (advanced override)
# If neither is set, we default to the original kustomize/ dir for backward compatibility.
OVERLAY=${OVERLAY:-}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${OVERLAY}" ]]; then
  if [[ "${OVERLAY}" == "base" ]]; then
    KUSTOMIZE_DIR="${SCRIPT_DIR}/base"
  else
    KUSTOMIZE_DIR="${SCRIPT_DIR}/overlays/${OVERLAY}"
  fi
else
  KUSTOMIZE_DIR=${KUSTOMIZE_DIR:-"${SCRIPT_DIR}/kustomize"}
fi

SCALE_UP_REPLICAS=${SCALE_UP_REPLICAS:-1}

log() { printf '\n[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required binary: $1" >&2; exit 1; }; }

need kubectl

log "Using namespace: ${NS}"
log "Using MinIO deployment: ${NS}/${MINIO_DEPLOY}"
log "Using kustomize dir: ${KUSTOMIZE_DIR}"

log "Scaling down MinIO (replicas=0)..."
kubectl -n "${NS}" scale deploy "${MINIO_DEPLOY}" --replicas=0
kubectl -n "${NS}" rollout status deploy "${MINIO_DEPLOY}" --timeout=120s || true

log "Deleting PVC ${NS}/minio (ignore if missing)..."
kubectl -n "${NS}" delete pvc minio --ignore-not-found

# Optional: if you are iterating, clear claimRef on PV if it exists and is Released.
# If PV doesn't exist, ignore.
log "If pv-minio-restore exists and is Released, clear its claimRef (ignore errors)..."
set +e
kubectl patch pv pv-minio-restore --type json -p='[{"op":"remove","path":"/spec/claimRef"}]' >/dev/null 2>&1
set -e

log "Applying kustomization (PV + PVC)..."
kubectl apply -k "${KUSTOMIZE_DIR}"

log "Waiting for PVC ${NS}/minio to bind..."
for i in {1..60}; do
  phase=$(kubectl -n "${NS}" get pvc minio -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [[ "${phase}" == "Bound" ]]; then
    log "PVC is Bound."
    break
  fi
  if [[ $i -eq 60 ]]; then
    log "PVC did not bind in time. Current PVC describe:" 
    kubectl -n "${NS}" describe pvc minio || true
    exit 1
  fi
  sleep 2
done

log "Scaling MinIO back up (replicas=${SCALE_UP_REPLICAS})..."
kubectl -n "${NS}" scale deploy "${MINIO_DEPLOY}" --replicas="${SCALE_UP_REPLICAS}"
kubectl -n "${NS}" rollout status deploy "${MINIO_DEPLOY}" --timeout=180s

log "Done."
