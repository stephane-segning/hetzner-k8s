# Hetzner Kubernetes Platform

A production-ready, self-managed Kubernetes cluster on Hetzner Cloud for small platforms, operated primarily through GitHub Actions.

## Overview

This repository provisions a **Hetzner-hosted k3s cluster** on Hetzner Cloud with:

- **Control plane**: 3 `CPX22` control-plane nodes by default
- **Workers**: 2 `CPX42` worker nodes by default
- **Cluster API**: Terraform-managed Hetzner TCP load balancer on `:6443`
- **CNI**: Cilium
- **Ingress**: Traefik exposed through a Kubernetes-managed Hetzner Load Balancer
- **Storage**: Hetzner CSI driver for persistent volumes
- **Networking**: Private network with firewall protection
- **Observability**: Grafana Alloy for telemetry collection
- **Data layer**: CloudNativePG (PostgreSQL) and Redis

## What This Provisions

### Infrastructure (Terraform)
- Hetzner private network and subnet
- Firewall rules (SSH, Kubernetes API, internal traffic)
- No public ingress to individual VMs; all public entry goes through load balancers
- Deterministic `CPX22` control-plane and `CPX42` worker nodes running Ubuntu 24.04 LTS
- 1 Terraform-managed API load balancer for Kubernetes access
- Optional worker-only data volumes for future Longhorn-style storage use

### Bootstrap (cloud-init/scripts)
- cloud-init driven k3s cluster initialization
- first control-plane bootstraps the cluster
- remaining control-plane and worker nodes join deterministically
- k3s nodes explicitly register their private Hetzner network IPs
- k3s runs with external cloud-provider mode so Hetzner CCM can own node cloud metadata and load balancer targets
- control-plane nodes take scheduled embedded-etcd snapshots and can replicate them to S3-compatible object storage
- swap disabled on every node before k3s starts
- k3s built-ins for flannel, local-storage, servicelb, and network-policy are disabled
- kubeconfig retrieval
- Cluster readiness verification

### Platform (manifests/helm)
- Cilium CNI
- Hetzner Cloud Controller Manager (CCM)
- Hetzner CSI driver
- Traefik ingress controller
- Namespaces: `platform`, `observability`, `data`, `apps`
- ServiceAccount and RBAC scaffolding for Argo CD and OIDC groups
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

Use this document as the index. For the first real validation run, follow `docs/testing-runbook.md`.

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
| `make init` | Initialize Terraform for local validation |
| `make plan` | Plan Terraform changes locally |
| `make apply` | Apply Terraform locally (break-glass only) |
| `make destroy` | Destroy Terraform locally (break-glass only) |
| `make bootstrap` | Bootstrap k3s cluster |
| `make platform-install` | Install Cilium and the base platform layer (`HCLOUD_TOKEN` + `HCLOUD_NETWORK` if no local Terraform state) |
| `make verify` | Verify cluster is healthy |
| `make test` | Run all tests |
| `make lint` | Lint all code |
| `make render` | Render all manifests |

## Recovery

### Full Rebuild

1. Trigger `Infra Destroy` in GitHub Actions
2. Trigger `Infra Up` in GitHub Actions
3. Wait for bootstrap readiness, retrieve kubeconfig, and rerun `make platform-install`

### Partial Recovery

If only k3s needs reinstall:

```bash
ssh root@<node-ip> sudo /usr/local/bin/k3s-uninstall.sh
make bootstrap
```

## Cost Estimate

| Resource | Monthly Cost |
|----------|--------------|
| 3x CPX22 control planes | ~€22-23 |
| 2x CPX42 workers | ~€32-33 |
| 1x Terraform-managed API LB | ~€7.49 |
| 1x Hetzner LB via Traefik service | ~€7.49 |
| 1x Object Storage backend | ~€6.49 |
| Traffic (est.) | ~€5-10 |
| **Total** | **~€96-102/month** |

## Security Baseline

- Private networking only (no public DB/Redis)
- Direct node public access to `6443` is disabled by default
- Public ingress to node `22`, `80`, and `443` is disabled by default
- Swap is disabled on all nodes
- Default-deny NetworkPolicies
- Firewall restricts to necessary ports
- No sensitive data in Git (use tfvars for secrets)
- RBAC enabled by default

## API Access

- Argo CD and human operators should use the Terraform-managed API endpoint from `api_server_endpoint`.
- The control-plane nodes only accept API traffic from the private network.
- The dedicated API load balancer provides a stable endpoint, but Hetzner load balancers do not currently give us the same server-side source IP allowlisting semantics as direct node firewalls when forwarding over the private network.
- Treat Kubernetes authentication and authorization as the primary security boundary for the public API endpoint unless you add an outer private-access layer.
- Configure a DNS hostname for the API endpoint and set `api_server_hostname` so the API certificate includes the load balancer access name.

## Identity And Access

- Argo CD should use a dedicated ServiceAccount token, not the static k3s admin kubeconfig.
- Human access should use Kubernetes OIDC against Keycloak.
- `Authorino` is appropriate for application APIs behind ingress, not for fronting the Kubernetes API server.
- The repo includes `platform/base/cluster-access.yaml` with:
  - `argocd-manager` ServiceAccount scaffold
  - a service-account token secret scaffold
  - `k8s-admins` and `k8s-viewers` OIDC group RBAC examples

## CI/CD Flows

- `Infra Up`: validates, plans, refuses accidental control-plane replacement unless explicitly allowed, applies Terraform, and powers on servers
- `Infra Down`: powers off Terraform-managed servers without destroying infra
- `Infra Destroy`: removes the known CCM-managed ingress LB and destroys Terraform-managed infrastructure
- `Platform Up`: installs Cilium and the base in-cluster platform layer using a bootstrap kubeconfig secret
- `Verify Etcd Backups`: verifies that recent etcd snapshots exist in S3

The default production posture is that embedded-etcd snapshots are replicated to S3-compatible object storage. The same Hetzner Object Storage service can back both Terraform state and etcd snapshots, but keep them separated by bucket or at least by prefix and retention policy.

Routine Terraform-driven control-plane replacement is not a supported steady-state operation in the current bootstrap model. Treat control-plane replacement as deliberate recovery or migration work, and verify S3-backed etcd snapshots before any disruptive maintenance.

## Next Steps

1. Point home-cluster Argo CD to this repository
2. Apply `platform/argocd/` Application manifests
3. Deploy workloads via GitOps

## Existing Cluster Note

If your cluster was bootstrapped before the private `node-ip` fix, reprovision or reinstall k3s on the nodes before expecting Hetzner load balancers with `use-private-ip: "true"` to behave correctly.

## Documentation

- [docs/architecture.md](./docs/architecture.md) - End-to-end architecture and ownership model
- [docs/access.md](./docs/access.md) - Human and automation access model
- [docs/testing-runbook.md](./docs/testing-runbook.md) - First-test sequence and acceptance criteria
- [docs/external-dns.md](./docs/external-dns.md) - Hetzner `external-dns` study and recommendation
- [DECISIONS.md](./DECISIONS.md) - Design decisions and rationale
- [TESTING.md](./TESTING.md) - Test strategy and coverage
- [docs/bootstrap.md](./docs/bootstrap.md) - Detailed bootstrap guide
- [docs/github-actions.md](./docs/github-actions.md) - GitHub Actions and remote state setup
- [docs/recovery.md](./docs/recovery.md) - Recovery procedures
