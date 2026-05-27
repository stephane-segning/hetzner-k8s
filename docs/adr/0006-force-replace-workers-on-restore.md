# ADR-0006: Force-replace workers on restore

## Status

Accepted

## Context

After the May 2026 restore landed cp-1 with the original cluster CA, the
workers refused to authenticate:

```
"Failed to validate server token: token CA hash does not match the Cluster CA certificate hash:
 454614d4d88c2acec9d5bdf6affb6364310b2a7b5315dc13b7f0a55bb121f702 !=
 328d8d5e6b72a7f353970fa0d798b7f63650f0c4304a51fc09f8c4c1fdf3dce8"
"tls: failed to verify certificate: x509: certificate signed by unknown authority"
```

`k3s-agent` pins the cluster CA fingerprint when it first joins
(`/var/lib/rancher/k3s/agent/server-ca-bootstrap-hash` and related
material). The workers in this run had joined the *empty cluster* created
by an earlier failed restore (sentinel/skip-enable from ADR-0004 was added
later). The restored API LB now serves certs signed by the snapshot's
original CA, and the agents reject every connection with a CA-mismatch
TLS error.

This is structurally analogous to the cp-2/cp-3 problem: the bootstrap
joining mechanism leaves state on the joining node that must match the
server's identity. When the server's identity changes (because we
restored a different CA), joiners need to be re-bootstrapped.

The non-bootstrap CPs are handled by ADR-0007 (gate-on-reachability).
Workers are simpler: they do not participate in etcd quorum, so their
in-parallel replacement has no quorum cost. They can be force-replaced
unconditionally on every `restore_from_s3=true` run.

## Decision

In the Infra Up workflow's `Terraform plan` step, when
`restore_from_s3=true`, append `-replace=module.servers.hcloud_server.main["worker-NN"]`
for every worker present in Terraform state:

```bash
terraform -chdir="$TF_DIR" state list \
  | grep -E '^module\.servers\.hcloud_server\.main\["worker-[0-9]+"\]$'
```

The replacements are computed dynamically from state so they scale to any
`worker_count`. The Terraform plan then destroys and recreates the worker
VMs. Their cloud-init runs fresh and `k3s-agent` installs against the
*current* API LB's CA, with no pinned fingerprint from a prior era.

## Consequences

- After a restore, workers reliably re-join the restored cluster on the
  first Infra Up run instead of looping forever on TLS verify errors.
- Workers lose any pod-local state (emptyDir, node-local PVCs — though
  the cluster disables `local-storage` per the design, so this is mostly
  N/A). PVC-bound storage is on Hetzner block volumes which survive worker
  destroy, and Hetzner CSI reattaches them to the new worker VMs on the
  next pod schedule.
- Worker replacement runs in parallel with the (possibly conditional)
  non-bootstrap CP replacement (ADR-0007). Terraform parallelizes destroy
  + create, so the worker churn does not extend the wall-clock time of a
  restore.
- A routine (non-restore) Infra Up run does *not* replace workers. This
  flag is `restore_from_s3`-only, so day-two upgrades and config changes
  don't churn worker VMs.
