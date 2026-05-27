# 9. Architecture Decisions

Big-picture design decisions live in [`DECISIONS.md`](../../DECISIONS.md)
at the repo root. Smaller, incremental decisions — especially the ones
learned the hard way through operational incidents — live as ADRs in
[`docs/adr/`](../adr/README.md).

## 9.1 Strategic decisions (DECISIONS.md)

These are the macro choices that shape the cluster:

- k3s on Ubuntu 24.04 LTS with embedded etcd (not external datastore)
- CPX22 for control planes, CPX42 for workers (cost/HA balance)
- Cilium CNI (not Flannel)
- Hetzner CCM + CSI via Helm (external cloud-provider mode)
- API LB is Terraform-managed; ingress LBs are CCM-managed
  (avoid split ownership)
- No public ingress to individual node IPs (port-22 SSH is break-glass only)
- OIDC against Keycloak for humans, ServiceAccount tokens for automation
- GitOps via Argo CD running in a separate home cluster

## 9.2 Incremental decisions (ADRs)

These came out of the cluster-restore work in May 2026 and codify the
lessons that the [lessons-learned doc](../lessons-learned/2026-05-cluster-restore.md)
narrates.

| #     | Title                                                                                                          | Closes failure mode                                            |
|-------|----------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------|
| 0001  | [Record architecture decisions](../adr/0001-record-architecture-decisions.md)                                  | (meta)                                                          |
| 0002  | [Restore etcd from S3 via Infra Up](../adr/0002-restore-etcd-from-s3-via-infra-up.md)                          | Operator can't SSH; need a GH-Actions-only recovery path        |
| 0003  | [Pre-decompress snapshot before `--cluster-reset-restore-path`](../adr/0003-pre-decompress-snapshot-before-cluster-reset.md) | k3s 1.35.x `decompressSnapshot` doubles `.zip` paths            |
| 0004  | [Idempotent restore via `INSTALL_K3S_SKIP_ENABLE` + sentinel](../adr/0004-idempotent-restore-skip-enable-sentinel.md) | Partial restore failure auto-rescues into empty cluster         |
| 0005  | [Bring up the Hetzner private NIC explicitly in cloud-init](../adr/0005-bring-up-private-nic-in-cloud-init.md) | Netplan race leaves private NIC `DOWN`                          |
| 0006  | [Force-replace workers on restore](../adr/0006-force-replace-workers-on-restore.md)                            | Workers' pinned CA hash rejects restored cluster's certs        |
| 0007  | [Gate non-bootstrap CP `-replace` on API reachability](../adr/0007-gate-cp-replace-on-api-reachability.md)    | Re-run destroys 2 of 3 voters; etcd loses quorum                |
| 0008  | [Self-validate Infra Up via `/livez` gate](../adr/0008-self-validate-infra-up-via-livez-gate.md)              | Workflow goes green while cluster is silently dead              |
| 0009  | [Use `mc` for inline S3 snapshot download during restore](../adr/0009-mc-for-inline-s3-download-during-restore.md) | k3s' built-in S3 path also hits the path-doubling bug           |
| 0010  | [Override `etcd-s3=false` on cluster-reset CLI](../adr/0010-etcd-s3-false-on-cluster-reset.md)                | config.yaml's `etcd-s3: true` re-enters the broken code path    |
| 0011  | [Pass `--node-ip` and `--advertise-address` to cluster-reset](../adr/0011-node-ip-on-cluster-reset.md)        | Restored member list records the public peer URL                |

## 9.3 How decisions are recorded

- DECISIONS.md is amended as the macro design evolves; treat it as a
  living design document with structured rationale.
- ADRs are **append-only**. To revise a decision, write a new ADR that
  references the old one as `Superseded by ADR-XXXX`.
- The trigger to write an ADR is any of:
  - A workflow change that codifies a non-obvious choice (e.g. a
    conditional `-replace` rule).
  - A cloud-init change that exists to dodge an upstream bug (cite the
    bug in the ADR).
  - A failure mode encountered in production that we now defend against
    in code.
