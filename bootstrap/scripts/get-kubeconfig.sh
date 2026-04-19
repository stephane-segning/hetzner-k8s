#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$PROJECT_ROOT/terraform/envs/prod"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

cd "$TF_DIR"

FIRST_NODE_IP=$(terraform output -raw first_control_plane_ip)
API_SERVER_HOST=$(terraform output -raw api_server_hostname)

if [ -z "$API_SERVER_HOST" ]; then
    API_SERVER_HOST=$(terraform output -raw api_load_balancer_ip)
fi

log "Retrieving kubeconfig from $FIRST_NODE_IP..."

ssh "root@$FIRST_NODE_IP" "cat /etc/rancher/k3s/k3s.yaml" | \
    sed "s/127.0.0.1/$API_SERVER_HOST/g" > "$PROJECT_ROOT/kubeconfig"

chmod 600 "$PROJECT_ROOT/kubeconfig"

log "Kubeconfig saved to $PROJECT_ROOT/kubeconfig"
log "Run: export KUBECONFIG=$PROJECT_ROOT/kubeconfig"
