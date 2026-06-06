# 7. Deployment View

## 7.1 Physical / cloud topology

Single region (default `nbg1`, Nuremberg), single Hetzner project.

```
Hetzner Cloud project
└── nbg1
    ├── Private network "ssegning-hetzner-k3s-network"
    │   └── Subnet 10.0.0.0/24 (within /16 network range)
    ├── Firewall "ssegning-hetzner-k3s"  (attached to all servers)
    │   └── rules: SSH 22/tcp, ICMP, intra-network all
    ├── Load balancer "ssegning-hetzner-k3s-api"  (lb11)
    │   └── service tcp/6443 → targets cp-01/02/03 on private-net :6443
    ├── 3 × CPX22 (control planes)
    │   ├── eth0   public IPv4 + IPv6
    │   └── enp7s0 private 10.0.0.10-12
    ├── 2-3 × CPX42 (workers)
    │   ├── eth0   public IPv4 + IPv6
    │   └── enp7s0 private 10.0.0.20-22
    └── CCM-managed LB "traefik-..."  (lb11)
        └── service tcp/80 + tcp/443 → traefik Pods (via Service annotations)

Hetzner Object Storage (separate but same project credentials)
├── bucket ssegning-k8s-state
│   └── terraform.tfstate
└── bucket (etcd) — folder ssegning-hetzner-k3s/etcd
    └── etcd-snapshot-ssegning-hetzner-k3s-cp-{1,2,3}-<unix>.zip × retention
```

## 7.2 Server specifications

| Role          | Count | Type  | vCPU | RAM   | Disk   | Notes                           |
|---------------|-------|-------|------|-------|--------|---------------------------------|
| control-plane | 3     | CPX22 | 3    | 4 GB  | 80 GB  | k3s server with embedded etcd   |
| worker        | 2-3   | CPX42 | 8    | 16 GB | 240 GB | k3s-agent; data volume optional |

Image: Ubuntu 24.04 LTS (Noble Numbat).

## 7.3 Network and firewall posture

- Single subnet `10.0.0.0/24` inside the project's private network.
- Deterministic private IP assignment (Terraform `cidrhost`):
    - cp-NN → `10.0.0.10 + (NN-1)`
    - worker-NN → `10.0.0.20 + (NN-1)`
- Public IPv4 on every server (used for outbound + SSH break-glass).
  Inbound public 80/443/6443 closed at firewall.
- Inbound public SSH (22) allowed at firewall (gated by SSH key, no
  password auth). Considered a break-glass and not the documented
  control surface.
- Intra-network traffic between all servers is open (firewall rule).
- API LB sits in the public Hetzner LB realm with a private-net target
  attachment to cp-{1,2,3}:6443. TCP forwarding (no L7 termination).
- CCM-managed Traefik LB has the same shape but at :80/:443.

## 7.4 DNS

- `api_server_hostname` (e.g. `k8s.ssegning.com`) is the operator-provided
  DNS name pointing at the API LB. Used as TLS SAN for the apiserver
  cert.
- Workload DNS records (e.g. `keycloak.ssegning.com`) point at the
  Traefik LB; these are managed outside this repo (operator's DNS
  provider).

## 7.5 Storage

- **Etcd data**: on the control-plane local disk
  `/var/lib/rancher/k3s/server/db/etcd/`. Replicated via raft across the
  three CPs.
- **Etcd snapshots**: local `/var/lib/rancher/k3s/server/db/snapshots/`
    + uploaded to S3 every 6 hours by k3s' built-in cron. Retention: 14
      locally per node (configurable via `etcd_snapshot_retention`),
      matching count in S3.
- **Workload PVCs**: provisioned via Hetzner CSI as Hetzner block
  volumes attached to the worker hosting the consuming Pod. Storage
  class `hcloud-volumes` (from the CSI Helm chart).
- **Worker data volume (optional)**: Terraform `create_data_volumes`
  flag creates an additional Hetzner volume per worker, attached at
  boot for future Longhorn-style storage. Not currently used.
- **Terraform state**: Hetzner Object Storage bucket via the S3
  Terraform backend.

## 7.6 Identity

- **k3s cluster bootstrap token**: random 32-byte string,
  `random_password.k3s_token` in Terraform state. Used for node
  joins. Survives `terraform destroy` of the servers as long as the
  state survives.
- **Human access**: OIDC against Keycloak (`OIDC_ISSUER_URL` env). The
  apiserver is configured with OIDC client ID, claim mappings.
- **Argo CD (home-cluster) access**: dedicated `argocd-manager`
  ServiceAccount + Token in the `platform` namespace, scoped wide enough
  to manage GitOps targets. Created by `platform/base/cluster-access.yaml`.
- **Hetzner Object Storage credentials**: GH Action secrets
  (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` for Terraform state;
  `ETCD_S3_ACCESS_KEY_ID` / `ETCD_S3_SECRET_ACCESS_KEY` for etcd
  snapshots).
