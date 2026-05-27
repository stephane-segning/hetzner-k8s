# 8. Crosscutting Concepts

## 8.1 Identity & secrets

- **Cluster CA** is created by k3s on first `--cluster-init` and lives in
  the etcd snapshot. Restoring etcd restores the CA: all certs signed
  thereafter chain back to the same root, which is the entire point of
  preserving the snapshot. **Implication**: workers and CPs that joined a
  *different* CA-era cluster cannot rejoin without being re-bootstrapped
  (see ADR-0006, ADR-0007).
- **K3s cluster token**: `random_password.k3s_token` in Terraform state.
  Must persist across infra destroy/recreate; this is the contract that
  lets re-provisioned nodes rejoin the restored cluster.
- **Hetzner Cloud token**: a single `HCLOUD_TOKEN` per environment, used
  by both Terraform (to provision) and Hetzner CCM/CSI (in-cluster).
  Lives as a GH Actions secret and is templated into a `kube-system`
  Secret by Platform Up.
- **etcd S3 credentials**: split lifecycle.
  - During *normal operation*: stored in the in-cluster Secret
    `k3s-etcd-snapshot-s3-config` (referenced by `--etcd-s3-config-secret`).
  - During *restore*: passed inline via cloud-init `user_data` because
    the in-cluster Secret doesn't exist yet (chicken-and-egg). After
    restore completes, Platform Up re-asserts the Secret.

## 8.2 Idempotency

Three layers of idempotency. Each closes a specific class of failure:

1. **Terraform idempotency** at the infra layer. State drives the truth;
   re-running Infra Up against an unchanged repo produces a no-op plan.
2. **Cloud-init idempotency** at the node layer. The
   `k3s-bootstrap.service` script checks `systemctl is-active k3s` early
   and exits 0 if k3s is already running. Combined with the recovery
   sentinel (ADR-0004), restore is also reentrant.
3. **Workflow idempotency** at the orchestration layer. `Infra Up` with
   `restore_from_s3=true` is safe to retry: the API-reachability gate
   (ADR-0007) decides what to `-replace` based on observable state.

## 8.3 Snapshots & restore

```mermaid
flowchart LR
    subgraph daily["Day-2"]
        CP1[cp-1 k3s] -->|cron 0 */6 * * *| Local1[/var/lib/.../snapshots/]
        CP2 -->|cron| Local2
        CP3 -->|cron| Local3
        Local1 -.->|--etcd-s3| S3[(Hetzner Object Storage)]
        Local2 -.-> S3
        Local3 -.-> S3
    end
    subgraph restore["Restore"]
        S3 -->|mc cp| Restore_local[/var/lib/.../snapshots/<basename>.zip]
        Restore_local -->|unzip -d| Uncompressed[/var/lib/.../snapshots/<basename>]
        Uncompressed -->|--cluster-reset-restore-path| Etcd[/var/lib/.../db/etcd/]
    end
```

Snapshot timestamps in the filename are Unix seconds. Local retention
defaults to 14 per node; S3 retention is controlled separately via the
`k3s-etcd-snapshot-s3-config` Secret. Restore picks **any one** snapshot
(by filename) — the data in all three same-timestamp snapshots is
identical.

## 8.4 Observability

- Workflow output: every workflow writes a summary to
  `GITHUB_STEP_SUMMARY` covering what was created/destroyed, what API
  endpoint resulted, and on failure the suspected cause.
- Cluster events: `kubectl get events -A` for the standard k8s view.
- Etcd snapshot inventory: `kubectl get etcdsnapshotfile`. Used by the
  `Verify Etcd Backups` workflow.
- Cilium identities and connectivity: `kubectl -n kube-system get pods
  -l k8s-app=cilium` + `cilium status` inside any Cilium pod.
- Remote observability: Grafana Alloy is scaffolded in `platform/`
  with remote-write to the home cluster's Grafana stack. Optional.

## 8.5 Failure modes and where they surface

| Failure                                       | Where it surfaces                                                                     | Where to look                                                  |
|-----------------------------------------------|----------------------------------------------------------------------------------------|----------------------------------------------------------------|
| cloud-init YAML parse error                   | Node up but k3s never installs; LB target unhealthy; `/livez` gate times out          | `cloud-init status --long` on the node; rendered user_data    |
| Private NIC race                              | k3s logs `bind: cannot assign requested address` on etcd port 2380                     | `ip addr show`, `journalctl -u k3s`                            |
| k3s cluster-reset path-doubling bug           | k3s logs `open ...snapshots/.../snapshots/...zip: no such file`                       | `/var/log/k3s-bootstrap.log` on cp-1                           |
| Restored member-list peer URL mismatch        | k3s.service `activating` forever; logs `this server is not a member of the etcd cluster` | `journalctl -u k3s` on cp-1                                    |
| Worker CA pinning                             | k3s-agent logs `x509: certificate signed by unknown authority`                         | `journalctl -u k3s-agent` on the worker                        |
| Etcd quorum break (CP destroy in parallel)    | API LB returns 503; cp-1 logs `authentication handshake failed: context deadline exceeded` | `journalctl -u k3s` on cp-1                                    |
| Stale Hetzner Object Storage cred             | `verify-etcd-backups` workflow fails; mc download in restore fails                    | Workflow logs; rotate creds; `make platform-up` to reassert    |
