# ADR-0004: Idempotent restore via `INSTALL_K3S_SKIP_ENABLE` and a sentinel

## Status

Accepted

## Context

Early iterations of the restore path used `INSTALL_K3S_SKIP_START=true` to
install k3s without starting it, then ran `--cluster-reset` manually, then
`systemctl start k3s`. Two failure modes were observed:

1. **Partial-failure auto-rescue.** A failed `--cluster-reset` left a
   half-populated `/var/lib/rancher/k3s/server/db/` on cp-1 (certs, lock
   files). Systemd's `k3s.service` was `enabled` by the install script. On
   the next boot, or when the operator manually `systemctl start k3s` to
   investigate, k3s saw the partial data dir, decided it was a normal
   start, and bootstrapped a **brand new empty cluster**. Other CPs and
   workers happily joined this empty cluster via the API LB. The original
   snapshot was untouched in S3, but the cluster was now a fresh empty
   thing pretending to be the real one.

2. **Re-running cluster-reset on a healthy cluster.** If cloud-init ran a
   second time (reboot, retry) on a successfully-restored cp-1, the script
   would run `--cluster-reset` *again*, this time against the populated
   etcd. k3s' `Restore()` renames the existing data dir aside and writes a
   new one from the snapshot — discarding any writes between the original
   restore and the second cloud-init run.

## Decision

Two changes layered together:

**1. Install without enabling the service.** Use
`INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true` in the curl|sh
install. The systemd unit gets the full flag set written to
`/etc/systemd/system/k3s.service`, but it is **not** enabled and **not**
started. Only after `--cluster-reset` exits successfully does the script
run `systemctl enable k3s && systemctl start k3s`. A partial failure
leaves the unit dormant; nothing can start it.

**2. Sentinel file `/var/lib/rancher/k3s/.recovery-restored`.** Created
with mode 0600 immediately after a successful `--cluster-reset`. The
cloud-init restore branch checks for it at the very top:

```bash
RECOVERY_SENTINEL=/var/lib/rancher/k3s/.recovery-restored
if [ -f "$RECOVERY_SENTINEL" ]; then
    log "Recovery sentinel present; restore already completed, starting k3s"
    systemctl enable k3s >/dev/null 2>&1 || true
    systemctl start k3s
    exit 0
fi
```

A second cloud-init run on the same node (reboot, systemd retry,
re-running `make bootstrap`) sees the sentinel and just starts k3s. The
`--cluster-reset` path is never re-entered against populated etcd.

## Consequences

- A failed `--cluster-reset` produces a clearly broken node (k3s.service
  inactive, no listener on `:6443`) instead of silently rescuing into an
  empty cluster. The Infra Up `/livez` gate (ADR-0008) then fails loudly.
- Retries are safe: re-running Infra Up against an unhealthy node either
  succeeds (sentinel absent, normal restore flow) or no-ops on the
  bootstrap CP (sentinel present, just start). The data dir is never
  destroyed by a re-run.
- The sentinel survives reboot but not VM replacement. A `terraform
  apply -replace=cp-1` correctly wipes it and re-runs the restore. This
  is the desired semantics: replacing the VM means "do the restore again
  from S3", which is what the operator just asked for.
- The sentinel is hand-written rather than derived from a k3s-managed
  state field. If the file gets deleted manually, the next reboot would
  redo cluster-reset against populated etcd — destructive. Mitigation:
  document the file as load-bearing; no other process touches it.
