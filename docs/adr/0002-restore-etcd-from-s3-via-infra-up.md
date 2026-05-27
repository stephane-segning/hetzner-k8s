# ADR-0002: Restore etcd from S3 via the Infra Up workflow

## Status

Accepted

## Context

The cluster takes etcd snapshots on a cron (`--etcd-snapshot-schedule-cron`,
default `0 */6 * * *`) on every control-plane node and uploads them to
Hetzner Object Storage via k3s' built-in S3 etcd backup feature. When the
control planes are lost (server-level destruction, accidental
`terraform destroy`, region-level incident on a CP host), the snapshots in
S3 remain available and are the only path back to a cluster containing
previous workload state.

The operating constraint is in `AGENTS.md`: GitHub Actions is the supported
control surface. The recovery flow must run end-to-end through
`workflow_dispatch` without requiring an operator to SSH to any node.

## Decision

Add a `restore_from_s3` mode to the **Infra Up** workflow
(`.github/workflows/infra-up.yml`). When set, the workflow:

1. Validates the operator supplied `restore_snapshot_name` and all
   `ETCD_S3_*` secrets (fail-fast before plan).
2. Pipes the snapshot identifier and S3 credentials into Terraform as
   variables (`TF_VAR_restore_from_s3`, `TF_VAR_restore_snapshot_name`,
   `TF_VAR_etcd_s3_*`), which cloud-init reads from `templatefile`-rendered
   user_data.
3. Terraform creates the bootstrap CP. Its cloud-init script, on the
   restore branch, downloads the snapshot from S3 (see ADR-0009), runs
   `k3s server --cluster-reset --cluster-reset-restore-path=<local>`, then
   starts k3s normally.
4. Non-bootstrap CPs join the restored cp-01 as new etcd members.
5. Workers reconnect via the API LB using the unchanged `K3S_TOKEN`
   (preserved across the destroy because `random_password.k3s_token` is in
   the remote Terraform state).

This makes restore a single-button operation: trigger Infra Up with the
restore inputs, wait for the `/livez` gate (ADR-0008) to flip green.

## Consequences

- No SSH or kubectl access required from the operator. A laptop that lost
  its kubeconfig can still recover the cluster.
- S3 credentials must arrive **inline** in cloud-init `user_data` during a
  restore (the in-cluster `k3s-etcd-snapshot-s3-config` Secret lives in the
  very etcd we are restoring). Cloud-init `user_data` shares the trust
  boundary of `HCLOUD_TOKEN`, so this is consistent with existing exposure
  but is worth noting and rotating after a restore.
- The restore path is opinionated about how the snapshot is loaded
  (ADR-0003), where the workflow re-replaces nodes (ADR-0007), and how the
  workflow self-validates (ADR-0008). Those are recorded separately to
  keep individual decisions small.
- The same workflow continues to be the path for routine
  no-restore Infra Up runs; `restore_from_s3` defaults to `false` and the
  restore-only logic is no-op'd off the hot path.
