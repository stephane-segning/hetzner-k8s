#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$PROJECT_ROOT/terraform/envs/prod"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "ERROR: $1" >&2
    exit 1
}

check_prerequisites() {
    log "Checking prerequisites..."
    
    command -v terraform >/dev/null 2>&1 || error "terraform is required"
    command -v jq >/dev/null 2>&1 || error "jq is required"
    command -v ssh >/dev/null 2>&1 || error "ssh is required"
    
    if [ ! -f "$TF_DIR/terraform.tfvars" ]; then
        error "terraform.tfvars not found. Copy terraform.tfvars.example and configure."
    fi
    
    if ! grep -q "YOUR_HCLOUD_TOKEN" "$TF_DIR/terraform.tfvars" 2>/dev/null; then
        :
    else
        error "Please update terraform.tfvars with your Hetzner API token"
    fi
    
    log "Prerequisites OK"
}

get_outputs() {
    log "Getting Terraform outputs..."
    
    cd "$TF_DIR"
    
    if [ ! -f "terraform.tfstate" ]; then
        error "No terraform state found. Run 'make apply' first."
    fi
    
    FIRST_CONTROL_PLANE_IP=$(terraform output -raw first_control_plane_ip)
    FIRST_CONTROL_PLANE_PRIVATE_IP=$(terraform output -raw first_control_plane_private_ip)
    CONTROL_PLANE_IPS=$(terraform output -json control_plane_public_ips | jq -r '.[]')
    WORKER_IPS=$(terraform output -json worker_public_ips | jq -r '.[]?')
    EXPECTED_NODES=$(terraform output -json server_details | jq 'length')
    
    export FIRST_CONTROL_PLANE_IP
    export FIRST_CONTROL_PLANE_PRIVATE_IP
    export CONTROL_PLANE_IPS
    export WORKER_IPS
    export EXPECTED_NODES
    
    log "Bootstrap control-plane IP: $FIRST_CONTROL_PLANE_IP"
    log "Bootstrap control-plane private IP: $FIRST_CONTROL_PLANE_PRIVATE_IP"
}

wait_for_ssh() {
    local ip="$1"
    local max_attempts=60
    local attempt=1
    
    log "Waiting for SSH on $ip..."
    
    while [ $attempt -le $max_attempts ]; do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes "root@$ip" "echo ready" 2>/dev/null; then
            log "SSH ready on $ip"
            return 0
        fi
        
        attempt=$((attempt + 1))
        sleep 5
    done
    
    error "SSH not available on $ip after $max_attempts attempts"
}

wait_for_nodes() {
    log "Waiting for all nodes to become reachable..."

    for ip in $CONTROL_PLANE_IPS; do
        wait_for_ssh "$ip"
    done

    for ip in $WORKER_IPS; do
        wait_for_ssh "$ip"
    done
}

wait_for_cluster() {
    local max_attempts=90
    local attempt=1

    log "Waiting for k3s API on $FIRST_CONTROL_PLANE_IP..."

    until ssh "root@$FIRST_CONTROL_PLANE_IP" "kubectl get nodes >/dev/null 2>&1"; do
        if [ $attempt -ge $max_attempts ]; then
            error "k3s API did not become ready in time"
        fi

        attempt=$((attempt + 1))
        log "Waiting for k3s API..."
        sleep 5
    done
}

verify_cluster() {
    log "Verifying cluster..."
    
    local max_attempts=90
    local attempt=1
    local ready_nodes=0

    while [ $attempt -le $max_attempts ]; do
        ready_nodes=$(ssh "root@$FIRST_CONTROL_PLANE_IP" "kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready '" || echo "0")

        if [ "$ready_nodes" -ge "$EXPECTED_NODES" ]; then
            break
        fi

        attempt=$((attempt + 1))
        log "Waiting for nodes to be Ready ($ready_nodes/$EXPECTED_NODES)..."
        sleep 5
    done

    ssh "root@$FIRST_CONTROL_PLANE_IP" "kubectl get nodes -o wide"

    if [ "$ready_nodes" -lt "$EXPECTED_NODES" ]; then
        error "Only $ready_nodes/$EXPECTED_NODES nodes are Ready"
    fi

    log "All $ready_nodes nodes are Ready"
}

get_kubeconfig() {
    log "Retrieving kubeconfig..."
    
    ssh "root@$FIRST_CONTROL_PLANE_IP" "cat /etc/rancher/k3s/k3s.yaml" | \
        sed "s/127.0.0.1/$FIRST_CONTROL_PLANE_IP/g" > "$PROJECT_ROOT/kubeconfig"
    
    chmod 600 "$PROJECT_ROOT/kubeconfig"
    
    log "Kubeconfig saved to $PROJECT_ROOT/kubeconfig"
}

main() {
    log "Starting k3s cluster bootstrap"
    
    check_prerequisites
    get_outputs
    wait_for_nodes
    wait_for_cluster
    verify_cluster
    get_kubeconfig
    
    log "Bootstrap complete!"
    log ""
    log "Next steps:"
    log "  1. export KUBECONFIG=$PROJECT_ROOT/kubeconfig"
    log "  2. kubectl get nodes"
    log "  3. Apply platform: kubectl apply -k platform/base/"
}

main "$@"
