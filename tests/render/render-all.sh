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

echo "Rendering Argo CD applications..."
mkdir -p "$OUTPUT_DIR/argocd"
for yaml in "$PROJECT_ROOT"/platform/argocd/*.yaml; do
    filename=$(basename "$yaml")
    cp "$yaml" "$OUTPUT_DIR/argocd/$filename"
done

if command -v helm >/dev/null 2>&1; then
    echo "Rendering Helm charts..."
    
    helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
    helm repo add cilium https://helm.cilium.io 2>/dev/null || true
    helm repo add cnpg https://cloudnative-pg.github.io/charts 2>/dev/null || true
    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
    helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update >/dev/null 2>&1
    
    mkdir -p "$OUTPUT_DIR/helm"
    
    helm template cilium cilium/cilium \
        --values "$PROJECT_ROOT/platform/helm-values/cilium-values.yaml" \
        --namespace kube-system > "$OUTPUT_DIR/helm/cilium.yaml" 2>/dev/null || echo "Warning: Failed to render cilium"

    helm template traefik traefik/traefik \
        --values "$PROJECT_ROOT/platform/helm-values/traefik-values.yaml" \
        --namespace traefik > "$OUTPUT_DIR/helm/traefik.yaml" 2>/dev/null || echo "Warning: Failed to render traefik"
    
    helm template cnpg cnpg/cloudnative-pg \
        --values "$PROJECT_ROOT/platform/helm-values/cnpg-values.yaml" \
        --namespace cnpg-system > "$OUTPUT_DIR/helm/cnpg.yaml" 2>/dev/null || echo "Warning: Failed to render cnpg"
    
    helm template redis bitnami/redis \
        --values "$PROJECT_ROOT/platform/helm-values/redis-values.yaml" \
        --namespace data > "$OUTPUT_DIR/helm/redis.yaml" 2>/dev/null || echo "Warning: Failed to render redis"
    
    helm template alloy grafana/alloy \
        --values "$PROJECT_ROOT/platform/helm-values/alloy-values.yaml" \
        --namespace observability > "$OUTPUT_DIR/helm/alloy.yaml" 2>/dev/null || echo "Warning: Failed to render alloy"
    
    helm template kube-state-metrics prometheus-community/kube-state-metrics \
        --values "$PROJECT_ROOT/platform/helm-values/kube-state-metrics-values.yaml" \
        --namespace observability > "$OUTPUT_DIR/helm/kube-state-metrics.yaml" 2>/dev/null || echo "Warning: Failed to render kube-state-metrics"
else
    echo "helm not installed, skipping chart rendering"
fi

echo "==> All manifests rendered to $OUTPUT_DIR"
