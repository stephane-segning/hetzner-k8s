# Workloads

This directory contains application workloads for the cluster.

## Structure

```
workloads/
├── sample-app.yaml      # Example application
├── cnpg-cluster.yaml    # PostgreSQL cluster definition
└── YOUR-APP.yaml        # Your applications here
```

## Adding Workloads

1. Create manifest files in this directory
2. Reference from Argo CD Application manifests
3. Commit and push for GitOps deployment

## Example Applications

### sample-app.yaml

A simple nginx deployment with:
- 2 replicas
- Service
- Ingress (requires DNS configuration)

### cnpg-cluster.yaml

A CloudNativePG PostgreSQL cluster with:
- 3 instances (HA)
- 10Gi storage
- Resource limits

## Deployment via Argo CD

Add to `platform/argocd/applications.yaml`:

```yaml
- name: workloads
  path: workloads
  namespace: apps
```

## Manual Deployment

```bash
kubectl apply -f workloads/
```
