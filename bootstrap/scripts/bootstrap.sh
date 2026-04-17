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
    
    FIRST_NODE_IP=$(terraform output -raw first_node_ip)
    FIRST_NODE_PRIVATE_IP=$(terraform output -raw first_node_private_ip)
    K3S_TOKEN=$(terraform output -raw k3s_token)
    NODE_IPS=$(terraform output -json ipv4_addresses | jq -r '.public[]')
    
    export FIRST_NODE_IP
    export FIRST_NODE_PRIVATE_IP
    export K3S_TOKEN
    export NODE_IPS
    
    log "First node IP: $FIRST_NODE_IP"
    log "First node private IP: $FIRST_NODE_PRIVATE_IP"
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

bootstrap_server() {
    log "Bootstrapping server node ($FIRST_NODE_IP)..."
    
    wait_for_ssh "$FIRST_NODE_IP"
    
    ssh "root@$FIRST_NODE_IP" "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server' sh -s - \
        --token='$K3S_TOKEN' \
        --cluster-init \
        --disable traefik \
        --disable servicelb \
        --write-kubeconfig-mode '0644'"
    
    log "Waiting for k3s server to be ready..."
    
    until ssh "root@$FIRST_NODE_IP" "kubectl get nodes" 2>/dev/null; do
        log "Waiting for k3s server..."
        sleep 5
    done
    
    log "Server node ready"
}

bootstrap_agents() {
    local agent_ips=()
    
    for ip in $NODE_IPS; do
        if [ "$ip" != "$FIRST_NODE_IP" ]; then
            agent_ips+=("$ip")
        fi
    done
    
    if [ ${#agent_ips[@]} -eq 0 ]; then
        log "No agent nodes to bootstrap"
        return 0
    fi
    
    for ip in "${agent_ips[@]}"; do
        log "Bootstrapping agent node ($ip)..."
        
        wait_for_ssh "$ip"
        
        ssh "root@$ip" "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='agent' sh -s - \
            --server='https://$FIRST_NODE_PRIVATE_IP:6443' \
            --token='$K3S_TOKEN'" &
    done
    
    wait
    
    log "Agent nodes bootstrapped"
}

verify_cluster() {
    log "Verifying cluster..."
    
    ssh "root@$FIRST_NODE_IP" "kubectl get nodes -o wide"
    
    local expected_nodes
    expected_nodes=$(echo "$NODE_IPS" | wc -l)
    local ready_nodes
    ready_nodes=$(ssh "root@$FIRST_NODE_IP" "kubectl get nodes --no-headers | grep -c Ready" || echo "0")
    
    if [ "$ready_nodes" -lt "$expected_nodes" ]; then
        log "Warning: Only $ready_nodes/$expected_nodes nodes are Ready"
    else
        log "All $ready_nodes nodes are Ready"
    fi
}

get_kubeconfig() {
    log "Retrieving kubeconfig..."
    
    ssh "root@$FIRST_NODE_IP" "cat /etc/rancher/k3s/k3s.yaml" | \
        sed "s/127.0.0.1/$FIRST_NODE_IP/g" > "$PROJECT_ROOT/kubeconfig"
    
    chmod 600 "$PROJECT_ROOT/kubeconfig"
    
    log "Kubeconfig saved to $PROJECT_ROOT/kubeconfig"
}

main() {
    log "Starting k3s cluster bootstrap"
    
    check_prerequisites
    get_outputs
    bootstrap_server
    bootstrap_agents
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
