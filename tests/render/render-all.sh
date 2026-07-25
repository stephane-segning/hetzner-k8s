#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"

mkdir -p "$OUTPUT_DIR"

echo "==> Rendering all manifests"

echo "Rendering platform/base..."
mkdir -p "$OUTPUT_DIR/platform"
for yaml in "$PROJECT_ROOT"/platform/base/*.yaml; do
    filename=$(basename "$yaml")
    cp "$yaml" "$OUTPUT_DIR/platform/$filename"
done

# Only the charts this repo actually installs are rendered (ADR-0020).
# Traefik, cnpg, redis, alloy and kube-state-metrics are owned by the home
# cluster's Argo CD with inline values — this repo has no say in them.
if command -v helm >/dev/null 2>&1; then
    echo "Rendering Helm charts..."

    helm repo add cilium https://helm.cilium.io 2>/dev/null || true
    helm repo add hcloud https://charts.hetzner.cloud 2>/dev/null || true
    helm repo update >/dev/null 2>&1

    mkdir -p "$OUTPUT_DIR/helm"
    
    helm template cilium cilium/cilium \
        --values "$PROJECT_ROOT/platform/helm-values/cilium-values.yaml" \
        --namespace kube-system > "$OUTPUT_DIR/helm/cilium.yaml" 2>/dev/null || echo "Warning: Failed to render cilium"

    helm template hccm hcloud/hcloud-cloud-controller-manager \
        --values "$PROJECT_ROOT/platform/helm-values/hcloud-ccm-values.yaml" \
        --namespace kube-system > "$OUTPUT_DIR/helm/hcloud-ccm.yaml" 2>/dev/null || echo "Warning: Failed to render hcloud-ccm"

    helm template hcloud-csi hcloud/hcloud-csi \
        --values "$PROJECT_ROOT/platform/helm-values/hcloud-csi-values.yaml" \
        --namespace kube-system > "$OUTPUT_DIR/helm/hcloud-csi.yaml" 2>/dev/null || echo "Warning: Failed to render hcloud-csi"

else
    echo "helm not installed, skipping chart rendering"
fi

echo "==> All manifests rendered to $OUTPUT_DIR"
