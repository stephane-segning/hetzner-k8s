# Design Decisions

This document records key decisions made during the design of this platform.

## Infrastructure

### Server Types: CPX22 Control Plane, CPX42 Workers

**Decision**: Use `CPX22` for control-plane nodes and `CPX42` for worker nodes

**Rationale**:
- `CPX22` is sufficient for small k3s control-plane nodes
- `CPX42` gives workers enough headroom for application workloads
- This stays within the target monthly budget while separating responsibilities

**Alternatives Considered**:
- `CPX42` everywhere: simpler but less cost efficient for control-plane nodes
- smaller worker nodes: less room for real workloads

### Node Layout: 3 Control-Plane Nodes, Optional Workers

**Decision**: 3 control-plane nodes by default, with a separate worker count that starts at 0

**Rationale**:
- k3s supports embedded etcd for HA with 3 nodes
- Keeps the initial cluster highly available
- Gives deterministic node roles and private IPs
- Leaves room to add dedicated worker pools later without redesigning Terraform

**Risks**:
- Workloads may impact control plane stability
- Mitigation: Use resource quotas and limits

### OS: Ubuntu 24.04 LTS

**Decision**: Ubuntu 24.04 LTS (Noble Numbat)

**Rationale**:
- Latest LTS release
- Long support window (to 2029)
- Good k3s compatibility
- Familiar tooling

**Alternatives Considered**:
- Debian 12: Less cloud-init documentation
- Rocky Linux 9: Less k3s testing

### Kubernetes Distribution: k3s

**Decision**: k3s (lightweight Kubernetes)

**Rationale**:
- Single binary, easy to install and maintain
- Lower resource usage than kubeadm
- Built-in Traefik (replaced with Helm-managed version)
- Embedded etcd option for HA
- Well-documented for Hetzner deployments

**Alternatives Considered**:
- kubeadm: More complex setup, higher resource usage
- k0s: Less community documentation
- Talos: More opinionated, steeper learning curve

### CNI: Cilium

**Decision**: Use Cilium instead of the default K3s Flannel CNI

**Rationale**:
- Gives a more capable networking and policy layer for future growth
- Fits the intent to enforce NetworkPolicies from the start
- Keeps the bootstrap explicit by disabling Flannel and installing the CNI deliberately

**Implementation**:
- Start k3s with `--flannel-backend=none`
- Disable the K3s network policy controller with `--disable-network-policy`
- Install Cilium via Helm/Argo CD in `kube-system`

### Swap: Disabled

**Decision**: Disable swap on all nodes before k3s starts

**Rationale**:
- Avoids kubelet instability and scheduling surprises in a default Kubernetes setup
- Matches common Kubernetes guidance unless NodeSwap is intentionally designed and tested

**Implementation**:
- `swapoff -a`
- comment swap entries in `/etc/fstab`
- mask `swap.target`

### K3s Local Storage: Disabled

**Decision**: Disable K3s `local-storage`

**Rationale**:
- Avoids mixed storage ownership and accidental use of node-local PVCs
- Keeps persistent storage on the Hetzner CSI path from day one

**Implementation**:
- Start k3s with `--disable local-storage`

## Networking

### Private Network Only

**Decision**: All nodes communicate via private network

**Rationale**:
- Reduces attack surface
- Lower latency between nodes
- Free traffic within Hetzner network
- DB/Redis not exposed publicly

**Implementation**:
- Hetzner private network (10.0.0.0/16)
- Firewall allows only: SSH, API server, internal traffic

### Load Balancer: Kubernetes/CCM-managed Hetzner LB

**Decision**: Let Kubernetes Services create Hetzner Load Balancers through Hetzner CCM

**Rationale**:
- Keeps ingress ownership in-cluster with the Traefik Service
- Avoids split ownership between Terraform and Kubernetes
- Matches the intended operational model for future GitOps handoff

**Alternative**: Ingress directly on node IPs
- Rejected: No HA, requires external LB or DNS failover

### Ingress: Traefik

**Decision**: Traefik via Helm (not built-in k3s Traefik)

**Rationale**:
- Version control via Helm values
- Easier to upgrade independently
- Better integration with Hetzner LB
- Argo CD can manage it

**Alternative**: nginx-ingress
- Rejected: Traefik is k3s native, better documented

## Storage

### CSI: Hetzner CSI Driver

**Decision**: Use Hetzner CSI for persistent volumes

**Rationale**:
- Native integration with Hetzner Cloud
- Dynamic volume provisioning
- Automatic volume attachment/detachment
- Supports ReadWriteOnce (sufficient for most workloads)

**Limitations**:
- ReadWriteOnce only (single node access)
- Not suitable for multi-writer workloads

**Alternative**: Longhorn
- Rejected: More complex, higher resource usage, not initially needed

## Observability

### Metrics Collection: Grafana Alloy

**Decision**: Deploy Grafana Alloy for telemetry collection

**Rationale**:
- Unified collector for metrics, logs, traces
- Native Kubernetes integration
- Remote write to home-cluster Grafana stack
- Lower resource usage than full Prometheus stack

**Implementation**:
- Minimal config for remote write
- Metrics collection from Kubernetes components
- Logs collection optional

### kube-state-metrics: Optional

**Decision**: Scaffold but make optional

**Rationale**:
- Provides Kubernetes object state metrics
- Useful for alerting on deployment state
- Can be enabled when home-cluster observability is ready

## Data Layer

### PostgreSQL: CloudNativePG (CNPG)

**Decision**: CNPG for PostgreSQL workloads

**Rationale**:
- Operator-pattern, declarative management
- Automatic failover and backups
- GitOps-friendly (CRDs for clusters)
- Active community

**Alternative**: Managed PostgreSQL (Hetzner doesn't offer)

### Redis: Bitnami Redis

**Decision**: Bitnami Redis Helm chart

**Rationale**:
- Well-maintained Helm chart
- Supports HA mode when needed
- GitOps-friendly

## Security

### NetworkPolicies: Default-Deny

**Decision**: Default-deny all ingress, explicit allow rules

**Rationale**:
- Defense in depth
- Prevents accidental exposure
- Required for compliance standards

**Implementation**:
- Namespace-level default deny
- Allow rules for:
  - DNS (kube-system)
  - Ingress controller
  - Sidecar injection (if needed)
  - Data layer internal traffic

### No Public Database Access

**Decision**: DB and Redis only accessible within cluster

**Rationale**:
- Reduces attack surface
- Prevents data exfiltration
- Forces proper access patterns (via applications)

## GitOps

### Argo CD Location: Home Cluster

**Decision**: Argo CD runs in separate home cluster, manages this remote cluster

**Rationale**:
- Separation of concerns
- GitOps controller survives remote cluster issues
- Can manage multiple remote clusters
- No Argo CD resource consumption in remote cluster

**Implementation**:
- Remote cluster registered to home Argo CD
- Application manifests in `platform/argocd/`
- Secrets for remote cluster access in home cluster

### Manifest Strategy: Plain YAML + Helm

**Decision**: Use plain YAML for platform, Helm values for packaged software

**Rationale**:
- Readable and version-controlled
- Helm for complex charts (Traefik, CNPG, Redis)
- Plain YAML for NetworkPolicies, Namespaces

**Alternative**: Kustomize
- Rejected: Adds complexity for minimal benefit in this case

## Testing

### Test Strategy

**Decision**: Static analysis + render validation

**Rationale**:
- No live infra for integration tests (cost)
- Terraform validate catches most errors
- Manifest validation via kubeconform
- Shell script linting via shellcheck

**Implementation**:
- `terraform fmt -check`
- `terraform validate`
- YAML schema validation
- Helm template render + validate

## Version Choices

| Component | Version | Reason |
|-----------|---------|--------|
| Terraform | ~> 1.6 | Latest stable |
| Hetzner Provider | ~> 1.49 | Latest with Hetzner features |
| Ubuntu | 24.04 LTS | Latest LTS |
| k3s | Latest stable | Automatic updates |
| Hetzner CCM | v1.30.1 | Latest stable |
| Hetzner CSI | v2.20.2 | Latest stable |
| Traefik Helm | v39.x | Latest for Traefik 3.x |
| CNPG | Latest | Operator manages versions |
| Grafana Alloy | Latest | Latest features |

## Risks

| Risk | Mitigation |
|------|------------|
| Single region failure | Accept for budget; can expand later |
| Combined nodes may starve control plane | Resource quotas, monitoring |
| k3s embedded etcd durability | Regular backups, document recovery |
| No automated backups yet | Manual process documented |
| No disaster recovery plan | Document rebuild procedure |

## Future Considerations

- Add dedicated worker nodes when scaling
- Implement automated backups
- Add Talos or similar for immutable infra
- Consider multi-region for HA
- Add external secrets operator for secret management
