# 4. Solution Strategy

## 4.1 Layering

The system is organized in four layers, each with a clear ownership
boundary:

```
┌────────────────────────────────────────────────────────────────────┐
│  Workloads                                                         │
│  (Argo CD-managed from home cluster: apps, CNPG, Redis, …)         │
├────────────────────────────────────────────────────────────────────┤
│  Platform                                                          │
│  (Cilium / Hetzner CCM / Hetzner CSI / Traefik / cluster-access)   │
│  Installed by Platform Up workflow; reconciled by Argo CD          │
├────────────────────────────────────────────────────────────────────┤
│  k3s                                                                │
│  (3 server + N agent; embedded etcd; OIDC for humans; SA tokens)   │
│  Installed by cloud-init at server creation                        │
├────────────────────────────────────────────────────────────────────┤
│  Infrastructure                                                    │
│  (Hetzner private network, firewall, servers, API LB, volumes)     │
│  Owned by Terraform; state in Hetzner Object Storage               │
└────────────────────────────────────────────────────────────────────┘
```

Lower layers don't depend on higher ones. Recovery moves bottom-up:
Terraform first, then k3s, then platform, then workloads (via Argo CD).

## 4.2 Key strategic decisions

| Decision                                                              | Why                                                                       | ADR / docs                                                       |
|-----------------------------------------------------------------------|---------------------------------------------------------------------------|------------------------------------------------------------------|
| GH Actions is the only supported control surface                      | Single, scriptable, audited entry point; survives operator-laptop changes | AGENTS.md                                                        |
| Terraform owns infrastructure; Kubernetes owns LBs from `type=LoadBalancer` | Avoid split ownership for ingress LBs                                | DECISIONS.md                                                     |
| Cloud-init self-bootstraps k3s on each node                           | No external bootstrapper to maintain; idempotent across reboots          | `bootstrap/cloud-init/node.yaml`                                 |
| etcd snapshots to S3 from every CP, every 6 hours                      | Decouple recovery from CP availability; cheap; resilient                 | DECISIONS.md, ADR-0002                                           |
| Restore from S3 is a single workflow input flip (`restore_from_s3`)    | No manual orchestration; predictable triage if it fails                   | ADR-0002, ADR-0008                                               |
| Restore pre-decompresses snapshot and passes local abs path            | Sidesteps k3s 1.35.x `decompressSnapshot` `.zip` path-doubling bug        | ADR-0003                                                         |
| Restore is idempotent via sentinel + `INSTALL_K3S_SKIP_ENABLE=true`    | Partial failure ≠ empty-cluster auto-rescue                              | ADR-0004                                                         |
| Cloud-init brings up the Hetzner private NIC explicitly                | Dodge the netplan-vs-attachment race                                     | ADR-0005                                                         |
| Workers are always re-provisioned on restore                          | Drop the pinned CA hash from any prior cluster era                       | ADR-0006                                                         |
| Non-bootstrap CPs are re-provisioned only when API is **not** reachable | Preserve etcd quorum on re-runs                                          | ADR-0007                                                         |
| Infra Up self-validates via `/livez` after apply                       | Green ⇒ reachable; no "did it actually work" loops                      | ADR-0008                                                         |
| Inline `mc` download for restore-time S3 fetch                         | Bypass k3s' broken S3-download path; explicit credential lifecycle       | ADR-0009                                                         |
| Override `etcd-s3=false` on cluster-reset CLI                          | Stop k3s' config.yaml from re-entering the broken S3 code path           | ADR-0010                                                         |
| `--node-ip` / `--advertise-address` on cluster-reset CLI               | Cluster-reset doesn't inherit them from the systemd unit                 | ADR-0011                                                         |

## 4.3 Mental model for the operator

Day-to-day:

1. Workload change → push to repo, home Argo CD picks it up.
2. Platform change (Cilium version, Traefik values, NetworkPolicy) →
   commit to repo, run **Platform Up**.
3. Infra change (server type, count, firewall) → commit, run **Infra Up**.

Recovery:

1. Lost CPs but workers + LB + state alive → **Infra Up** with
   `restore_from_s3=true` and the snapshot filename.
2. Lost everything (full DR) → **Infra Up** with `restore_from_s3=true`
   (Terraform will create everything from scratch; cp-1 still restores
   from the S3 snapshot).
3. Want to rotate just workers (e.g. after platform change) → routine
   **Infra Up**, optionally with `terraform apply -replace` for
   specific workers; the workflow will re-run cloud-init on them.
