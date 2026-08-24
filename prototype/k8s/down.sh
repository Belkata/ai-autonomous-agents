#!/usr/bin/env bash
#
# k8s/down.sh — tear down the namespace (agent pod, proxy, github-mcp, all
# their Secrets/PVCs). Leaves the k3d cluster itself running, since
# recreating it is the slow part; pass --cluster to delete that too.
#
# Usage: k8s/down.sh [--cluster]

set -euo pipefail

CLUSTER_NAME="${AI_SANDBOX_K8S_CLUSTER:-ai-sandbox}"
NAMESPACE="${AI_SANDBOX_K8S_NAMESPACE:-agent-sandbox}"
CONTEXT="k3d-$CLUSTER_NAME"

log() { printf '[k8s/down] %s\n' "$*"; }

if kubectl --context "$CONTEXT" get ns "$NAMESPACE" >/dev/null 2>&1; then
  log "deleting namespace $NAMESPACE (this deletes any live opencode session state too)"
  kubectl --context "$CONTEXT" delete ns "$NAMESPACE"
else
  log "namespace $NAMESPACE not found — nothing to do"
fi

if [ "${1:-}" = "--cluster" ]; then
  log "deleting k3d cluster $CLUSTER_NAME"
  k3d cluster delete "$CLUSTER_NAME"
fi
