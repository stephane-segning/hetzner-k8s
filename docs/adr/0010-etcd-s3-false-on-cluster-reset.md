# ADR-0010: Override `etcd-s3=false` on the cluster-reset CLI

## Status

Accepted

## Context

`/etc/rancher/k3s/config.yaml` is templated by cloud-init to carry the
ongoing-operations etcd S3 config:

```yaml
etcd-s3: true
etcd-s3-config-secret: k3s-etcd-snapshot-s3-config
```

These settings drive the cron-scheduled snapshot uploads from the running
cluster. They are *necessary* for normal operation. But k3s merges
`config.yaml` into **every** `k3s server` invocation, including the
one-shot `--cluster-reset` we run during restore. With `etcd-s3: true`
implicitly set, k3s' `Restore()` enters the S3 download code path even
though we (ADR-0009) already downloaded the snapshot locally with `mc`
and just want to point at a file. That re-enters the broken
`decompressSnapshot` filepath.Join code path (ADR-0003).

## Decision

Pass `--etcd-s3=false` explicitly on the cluster-reset CLI:

```bash
/usr/local/bin/k3s server \
  --cluster-reset \
  --cluster-reset-restore-path="$SNAP_RESTORE" \
  --token "$K3S_TOKEN" \
  --node-ip "$NODE_PRIVATE_IP" \
  --advertise-address "$NODE_PRIVATE_IP" \
  --etcd-s3=false \
  >>"$LOG" 2>&1
```

CLI flags override config.yaml, so the one-shot restore takes the local
path branch. After restore completes and `systemctl start k3s` brings up
the regular service, config.yaml's `etcd-s3: true` is back in effect and
cron snapshots continue uploading.

## Consequences

- Restore stays on the local-path code path, dodging the S3-download
  variant of the doubled-path bug.
- The cluster-reset invocation no longer needs S3 credentials passed
  through to k3s (only `mc` needs them — the `k3s server --cluster-reset`
  call has no `--etcd-s3-*` flags at all).
- The override is targeted: it applies only to the cluster-reset process.
  The regular k3s service started after cluster-reset reads config.yaml
  normally and re-engages S3 upload for cron snapshots.
- Future k3s versions may change this CLI semantics. If `--etcd-s3=false`
  stops overriding config.yaml, the restore would resume hitting the
  S3-download bug. Mitigation: the bug itself is upstream-tracked and
  expected to be fixed, at which point this override becomes unnecessary.
