# Hetzner Kubernetes Platform

A production-ready, self-managed Kubernetes cluster on Hetzner Cloud for small platforms, operated primarily through GitHub Actions.

## Overview

This repository provisions a **Hetzner-hosted k3s cluster** on Hetzner Cloud with:

- **Control plane**: 3 `CPX22` control-plane nodes by default
- **Workers**: 2 `CPX42` worker nodes by default
- **Cluster API**: Terraform-managed Hetzner TCP load balancer on `:6443`
- **Ingress**: Traefik exposed through a Kubernetes-managed Hetzner Load Balancer
- **Storage**: Hetzner CSI driver for persistent volumes
- **Networking**: Private network with firewall protection
- **Observability**: Grafana Alloy for telemetry collection
- **Data layer**: CloudNativePG (PostgreSQL) and Redis

## What This Provisions

### Infrastructure (Terraform)
- Hetzner private network and subnet
- Firewall rules (SSH, Kubernetes API, internal traffic)
- Deterministic `CPX22` control-plane and `CPX42` worker nodes running Ubuntu 24.04 LTS
- 1 Terraform-managed API load balancer for Kubernetes access
- Optional data volumes

### Bootstrap (cloud-init/scripts)
- cloud-init driven k3s cluster initialization
- first control-plane bootstraps the cluster
- remaining control-plane and worker nodes join deterministically
- kubeconfig retrieval
- Cluster readiness verification

### Platform (manifests/helm)
- Hetzner Cloud Controller Manager (CCM)
- Hetzner CSI driver
- Traefik ingress controller
- Namespaces: `platform`, `observability`, `data`, `apps`
- Default-deny NetworkPolicies
- Grafana Alloy (scaffolded)
- kube-state-metrics (optional)

## What This Does NOT Provision

- **Argo CD**: Remains in home cluster (GitOps controller)
- **Istio**: Not included (complexity)
- **SPIRE**: Not included (complexity)
- **Longhorn**: Not included (using Hetzner CSI instead)
- **Karrio**: Not included (application-specific)
- **Monitoring stack**: Grafana/Prometheus in home cluster

## Ownership Model

| Component | Owned By | Managed By |
|-----------|----------|------------|
| Hetzner infra (servers, network, firewall) | Terraform | Terraform |
| Kubernetes API load balancer (`:6443`) | Terraform | Terraform |
| OS bootstrap (k3s install) | Terraform | Terraform |
| In-cluster platform (CCM, CSI, Traefik) | Argo CD | Argo CD |
| Hetzner ingress load balancer | Kubernetes + Hetzner CCM | Kubernetes + Hetzner CCM |
| Workloads (CNPG, Redis, apps) | Argo CD | Argo CD |
| NetworkPolicies | Argo CD | Argo CD |

## Quick Start

### Prerequisites

- Hetzner Cloud API token
- SSH key pair
- Hetzner Object Storage bucket for Terraform state
- GitHub repository secrets and variables configured

For local validation only:

- Terraform >= 1.6
- kubectl
- helm

### 1. Configure GitHub Actions

Prefer the GitHub Actions workflows in `.github/workflows/`.

Set the required secrets and variables described in [docs/github-actions.md](./docs/github-actions.md).

This is the supported operational path for provisioning, power-off, and destroy.

### 2. Trigger Infrastructure Workflow

Use GitHub Actions:

- `Infra Up`
- `Infra Down`
- `Infra Destroy`

### 3. Optional Local Validation

```bash
cp terraform/envs/prod/terraform.tfvars.example terraform/envs/prod/terraform.tfvars
# Edit terraform.tfvars only if you need local validation
```

Do not commit `terraform.tfvars` or any `.bak` variant. They are local-only.

### 4. Optional Local Validation Commands

```bash
make init
make test
```

## Directory Structure

```
.
├── terraform/           # Infrastructure as code
│   ├── modules/         # Reusable Terraform modules
│   └── envs/prod/       # Production environment
├── bootstrap/           # Cluster bootstrap scripts
│   ├── cloud-init/      # User-data templates
│   └── scripts/         # Bootstrap automation
├── platform/            # In-cluster platform manifests
│   ├── base/            # Core manifests
│   ├── helm-values/     # Helm value files
│   └── argocd/          # Argo CD Application manifests
├── workloads/           # Application workloads
├── tests/               # Validation tests
│   ├── unit/            # Unit tests
│   └── render/          # Render validation
├── docs/                # Additional documentation
├── Makefile             # Automation commands
├── DECISIONS.md         # Design decisions
└── TESTING.md           # Test documentation
```

## Make Commands

| Command | Description |
|---------|-------------|
| `make init` | Initialize Terraform |
| `make plan` | Plan Terraform changes |
| `make apply` | Apply Terraform infrastructure |
| `make destroy` | Destroy infrastructure |
| `make bootstrap` | Bootstrap k3s cluster |
| `make verify` | Verify cluster is healthy |
| `make test` | Run all tests |
| `make lint` | Lint all code |
| `make render` | Render all manifests |

## Recovery

### Full Rebuild

1. Trigger `Infra Destroy` in GitHub Actions
2. Trigger `Infra Up` in GitHub Actions
3. Wait for bootstrap readiness and retrieve kubeconfig

### Partial Recovery

If only k3s needs reinstall:

```bash
./bootstrap/scripts/reset-k3s.sh
./bootstrap/scripts/bootstrap.sh
```

## Cost Estimate

| Resource | Monthly Cost |
|----------|--------------|
| 3x CPX22 control planes | ~€22-23 |
| 2x CPX42 workers | ~€32-33 |
| 1x Hetzner LB via Traefik service | ~€5.83 |
| Traffic (est.) | ~€5-10 |
| **Total** | **~€60-70/month** |

## Security Baseline

- Private networking only (no public DB/Redis)
- Direct node public access to `6443` is disabled by default
- Default-deny NetworkPolicies
- Firewall restricts to necessary ports
- No sensitive data in Git (use tfvars for secrets)
- RBAC enabled by default

## API Access

- Argo CD and human operators should use the Terraform-managed API endpoint from `api_server_endpoint`.
- The control-plane nodes only accept API traffic from the private network by default.
- The dedicated API load balancer provides a stable endpoint, but Hetzner load balancers do not currently give us the same server-side source IP allowlisting semantics as direct node firewalls when forwarding over the private network.
- Treat Kubernetes authentication and authorization as the primary security boundary for the public API endpoint unless you add an outer private-access layer.

## CI/CD Flows

- `Infra Up`: validates, applies Terraform, and powers on servers
- `Infra Down`: powers off Terraform-managed servers without destroying infra
- `Infra Destroy`: removes the known CCM-managed ingress LB and destroys Terraform-managed infrastructure

## Next Steps

1. Point home-cluster Argo CD to this repository
2. Apply `platform/argocd/` Application manifests
3. Deploy workloads via GitOps

## Documentation

- [DECISIONS.md](./DECISIONS.md) - Design decisions and rationale
- [TESTING.md](./TESTING.md) - Test strategy and coverage
- [docs/bootstrap.md](./docs/bootstrap.md) - Detailed bootstrap guide
- [docs/github-actions.md](./docs/github-actions.md) - GitHub Actions and remote state setup
- [docs/recovery.md](./docs/recovery.md) - Recovery procedures
