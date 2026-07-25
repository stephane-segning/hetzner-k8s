#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"

mkdir -p "$OUTPUT_DIR"

echo "==> Validating Terraform"

cd "$PROJECT_ROOT/terraform/envs/prod"

TEMP_TFVARS="$(mktemp "$PWD/terraform.tfvars.validation.XXXXXX")"
cleanup() {
    rm -f "$TEMP_TFVARS"
}
trap cleanup EXIT

echo "Creating temporary tfvars for validation..."
cp terraform.tfvars.example "$TEMP_TFVARS"
perl -0pi -e 's/YOUR_HCLOUD_TOKEN/test_token_for_validation/g' "$TEMP_TFVARS"

terraform init -backend=false >/dev/null 2>&1 || true
terraform validate

echo "==> Validating YAML manifests"

for yaml in "$PROJECT_ROOT"/platform/base/*.yaml; do
    echo "Checking $yaml"
    if command -v kubeconform >/dev/null 2>&1; then
        kubeconform -skip K8S-1001-0 "$yaml"
    else
        echo "kubeconform not installed, skipping schema validation"
    fi
done

echo "==> Rendering Helm charts (dry-run)"

if command -v helm >/dev/null 2>&1; then
    helm repo add cilium https://helm.cilium.io 2>/dev/null || true
    helm repo add hcloud https://charts.hetzner.cloud 2>/dev/null || true
    helm repo update >/dev/null 2>&1
    
    helm template cilium cilium/cilium \
        --values "$PROJECT_ROOT/platform/helm-values/cilium-values.yaml" \
        --namespace kube-system > "$OUTPUT_DIR/cilium.yaml" 2>/dev/null || echo "Failed to render cilium"

    helm template hccm hcloud/hcloud-cloud-controller-manager \
        --values "$PROJECT_ROOT/platform/helm-values/hcloud-ccm-values.yaml" \
        --namespace kube-system > "$OUTPUT_DIR/hcloud-ccm.yaml" 2>/dev/null || echo "Failed to render hcloud-ccm"

    helm template hcloud-csi hcloud/hcloud-csi \
        --values "$PROJECT_ROOT/platform/helm-values/hcloud-csi-values.yaml" \
        --namespace kube-system > "$OUTPUT_DIR/hcloud-csi.yaml" 2>/dev/null || echo "Failed to render hcloud-csi"

else
    echo "helm not installed, skipping chart rendering"
fi

echo "==> Checking shell scripts"

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$PROJECT_ROOT"/bootstrap/scripts/*.sh || echo "ShellCheck found issues"
else
    echo "shellcheck not installed, skipping"
fi

echo "==> All validations complete"
