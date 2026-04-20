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

ensure_prerequisites() {
    command -v kubectl >/dev/null 2>&1 || error "kubectl is required"
    command -v helm >/dev/null 2>&1 || error "helm is required"

    if [ -z "${KUBECONFIG:-}" ]; then
        if [ -f "$PROJECT_ROOT/kubeconfig" ]; then
            export KUBECONFIG="$PROJECT_ROOT/kubeconfig"
        else
            error "KUBECONFIG is not set and $PROJECT_ROOT/kubeconfig does not exist"
        fi
    fi

    kubectl version --request-timeout=10s >/dev/null 2>&1 || error "kubectl cannot reach the cluster"
}

terraform_outputs_available() {
    command -v terraform >/dev/null 2>&1 && terraform -chdir="$TF_DIR" output -raw network_id >/dev/null 2>&1
}

resolve_hetzner_inputs() {
    if terraform_outputs_available; then
        log "Using Hetzner secret manifests from Terraform outputs"
        HCLOUD_CCM_SECRET_MANIFEST=$(terraform -chdir="$TF_DIR" output -raw hcloud_ccm_secret_manifest)
        HCLOUD_CSI_SECRET_MANIFEST=$(terraform -chdir="$TF_DIR" output -raw hcloud_csi_secret_manifest)
        return
    fi

    : "${HCLOUD_TOKEN:?HCLOUD_TOKEN is required when Terraform outputs are unavailable}"
    : "${HCLOUD_NETWORK:?HCLOUD_NETWORK is required when Terraform outputs are unavailable}"

    log "Using Hetzner secret manifests from environment variables"
    HCLOUD_CCM_SECRET_MANIFEST=$(cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: hcloud
  namespace: kube-system
stringData:
  token: "${HCLOUD_TOKEN}"
  network: "${HCLOUD_NETWORK}"
EOF
)
    HCLOUD_CSI_SECRET_MANIFEST=$(cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: hcloud-csi
  namespace: kube-system
stringData:
  token: "${HCLOUD_TOKEN}"
EOF
)
}

is_truthy() {
    case "${1:-}" in
        1|true|TRUE|True|yes|YES|on|ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

normalize_https_endpoint() {
    local endpoint="${1:-}"

    case "$endpoint" in
        http://*|https://*)
            printf '%s\n' "$endpoint"
            ;;
        *)
            printf 'https://%s\n' "$endpoint"
            ;;
    esac
}

apply_namespaces() {
    log "Applying base namespaces"
    kubectl apply -f "$PROJECT_ROOT/platform/base/namespaces.yaml"
}

install_cilium() {
    log "Installing Cilium"
    helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1
    helm upgrade --install cilium cilium/cilium \
        --namespace kube-system \
        --values "$PROJECT_ROOT/platform/helm-values/cilium-values.yaml"

    kubectl rollout status daemonset/cilium -n kube-system --timeout=10m
    kubectl rollout status deployment/cilium-operator -n kube-system --timeout=10m
}

apply_hetzner_secrets() {
    log "Applying Hetzner secret manifests"
    printf '%s\n' "$HCLOUD_CCM_SECRET_MANIFEST" | kubectl apply -f -
    printf '%s\n' "$HCLOUD_CSI_SECRET_MANIFEST" | kubectl apply -f -

    kubectl get secret hcloud -n kube-system >/dev/null
    kubectl get secret hcloud-csi -n kube-system >/dev/null
}

apply_etcd_snapshot_s3_secret() {
    local secret_name bucket endpoint access_key secret_key region folder retention lookup_type timeout
    local etcd_s3_required="false"

    if is_truthy "${ETCD_S3_ENABLED:-${TF_VAR_etcd_s3_enabled:-}}"; then
        etcd_s3_required="true"
    fi

    if [ -z "${ETCD_S3_BUCKET:-}" ] && [ -z "${ETCD_S3_ENDPOINT:-}" ] && [ -z "${ETCD_S3_ACCESS_KEY_ID:-}" ] && [ -z "${ETCD_S3_SECRET_ACCESS_KEY:-}" ]; then
        if [ "$etcd_s3_required" = "true" ]; then
            error "etcd S3 backups are enabled but ETCD_S3_* settings are missing"
        fi

        log "Skipping k3s etcd snapshot S3 secret; ETCD_S3_* inputs are not set"
        return
    fi

    : "${ETCD_S3_BUCKET:?ETCD_S3_BUCKET is required when configuring etcd snapshot S3 backups}"
    : "${ETCD_S3_ENDPOINT:?ETCD_S3_ENDPOINT is required when configuring etcd snapshot S3 backups}"
    : "${ETCD_S3_ACCESS_KEY_ID:?ETCD_S3_ACCESS_KEY_ID is required when configuring etcd snapshot S3 backups}"
    : "${ETCD_S3_SECRET_ACCESS_KEY:?ETCD_S3_SECRET_ACCESS_KEY is required when configuring etcd snapshot S3 backups}"

    secret_name="${ETCD_S3_CONFIG_SECRET_NAME:-${TF_VAR_etcd_s3_config_secret_name:-k3s-etcd-snapshot-s3-config}}"
    bucket="${ETCD_S3_BUCKET}"
    endpoint="$(normalize_https_endpoint "${ETCD_S3_ENDPOINT}")"
    access_key="${ETCD_S3_ACCESS_KEY_ID}"
    secret_key="${ETCD_S3_SECRET_ACCESS_KEY}"
    region="${ETCD_S3_REGION:-eu-central}"
    folder="${ETCD_S3_FOLDER:-${TF_VAR_cluster_name:-hetzner-k8s}/etcd}"
    retention="${ETCD_S3_RETENTION:-${TF_VAR_etcd_snapshot_retention:-14}}"
    lookup_type="${ETCD_S3_BUCKET_LOOKUP_TYPE:-path}"
    timeout="${ETCD_S3_TIMEOUT:-5m}"

    log "Applying k3s etcd snapshot S3 secret '$secret_name'"
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: kube-system
type: etcd.k3s.cattle.io/s3-config-secret
stringData:
  etcd-s3-access-key: "${access_key}"
  etcd-s3-bucket: "${bucket}"
  etcd-s3-bucket-lookup-type: "${lookup_type}"
  etcd-s3-endpoint: "${endpoint}"
  etcd-s3-folder: "${folder}"
  etcd-s3-insecure: "false"
  etcd-s3-region: "${region}"
  etcd-s3-retention: "${retention}"
  etcd-s3-secret-key: "${secret_key}"
  etcd-s3-skip-ssl-verify: "false"
  etcd-s3-timeout: "${timeout}"
EOF

    kubectl get secret "${secret_name}" -n kube-system >/dev/null
}

install_ccm_and_csi() {
    log "Installing Hetzner CCM and CSI via official Helm charts"

    helm repo add hcloud https://charts.hetzner.cloud >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1

    if ! helm status hccm -n kube-system >/dev/null 2>&1; then
        kubectl delete -f "$PROJECT_ROOT/platform/base/hcloud-ccm.yaml" --ignore-not-found=true >/dev/null 2>&1 || true
    fi

    if ! helm status hcloud-csi -n kube-system >/dev/null 2>&1; then
        kubectl delete -f "$PROJECT_ROOT/platform/base/hcloud-csi.yaml" --ignore-not-found=true >/dev/null 2>&1 || true
        kubectl delete csidriver csi.hetzner.cloud --ignore-not-found=true >/dev/null 2>&1 || true
        kubectl delete storageclass hcloud-volumes --ignore-not-found=true >/dev/null 2>&1 || true
    fi

    helm upgrade --install hccm hcloud/hcloud-cloud-controller-manager \
        --namespace kube-system \
        --values "$PROJECT_ROOT/platform/helm-values/hcloud-ccm-values.yaml"

    helm upgrade --install hcloud-csi hcloud/hcloud-csi \
        --namespace kube-system \
        --values "$PROJECT_ROOT/platform/helm-values/hcloud-csi-values.yaml"

    kubectl rollout status deployment/hcloud-cloud-controller-manager -n kube-system --timeout=10m
    kubectl rollout status deployment/hcloud-csi-controller -n kube-system --timeout=10m
    kubectl rollout status daemonset/hcloud-csi-node -n kube-system --timeout=10m
}

install_traefik() {
    log "Installing Traefik"
    helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1
    helm upgrade --install traefik traefik/traefik \
        --namespace traefik \
        --create-namespace \
        --values "$PROJECT_ROOT/platform/helm-values/traefik-values.yaml"

    kubectl rollout status deployment/traefik -n traefik --timeout=10m
}

apply_cluster_basics() {
    log "Applying cluster access and NetworkPolicies"
    kubectl apply -f "$PROJECT_ROOT/platform/base/cluster-access.yaml"
    kubectl apply -f "$PROJECT_ROOT/platform/base/networkpolicy-default-deny.yaml"
    kubectl apply -f "$PROJECT_ROOT/platform/base/networkpolicy-dns.yaml"
    kubectl apply -f "$PROJECT_ROOT/platform/base/networkpolicy-data.yaml"
    kubectl apply -f "$PROJECT_ROOT/platform/base/networkpolicy-ingress.yaml"
}

show_summary() {
    log "Platform installation complete"
    kubectl get nodes -o wide
    echo
    kubectl get pods -A
    echo
    log "Next checks:"
    log "  kubectl get svc -n traefik"
    log "  kubectl get storageclass"
    log "  kubectl -n platform get secret argocd-manager-token"
}

main() {
    ensure_prerequisites
    resolve_hetzner_inputs
    apply_namespaces
    install_cilium
    apply_hetzner_secrets
    apply_etcd_snapshot_s3_secret
    install_ccm_and_csi
    install_traefik
    apply_cluster_basics
    show_summary
}

main "$@"
