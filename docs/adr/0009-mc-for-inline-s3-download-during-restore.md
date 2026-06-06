# ADR-0009: Use `mc` for inline S3 snapshot download during restore

## Status

Accepted

## Context

`k3s server --cluster-reset --cluster-reset-restore-path=<file>` accepts
both a local path and an S3 location (with `--etcd-s3` and S3 credential
flags). The S3 code path inside k3s 1.35.x hits the path-doubling bug
documented in ADR-0003 even more reliably than the local path, because
k3s sets `ClusterResetRestorePath` to the absolute path of the downloaded
file before calling `decompressSnapshot`.

We need the snapshot file on the local disk before invoking k3s anyway
(ADR-0003 mandates pre-decompression). Downloading it ourselves removes
the dependency on k3s' S3 client entirely.

S3 credentials for this download must arrive via cloud-init `user_data`
because the in-cluster `k3s-etcd-snapshot-s3-config` Secret lives in the
very etcd we are restoring (chicken-and-egg).

Tooling options considered:

- `aws-cli` — heavy (Python runtime + ~30 MB), comes from apt
- `s5cmd` — fast, single Go binary, but a less-common project
- `mc` (MinIO Client) — single static Go binary, widely deployed, S3
  protocol fully compatible with Hetzner Object Storage
- `curl` with hand-rolled AWS SigV4 — possible but fragile to write
  inline in bash

## Decision

Download `mc` from the official MinIO mirror at restore time and use it
for the snapshot download:

```bash
curl -fsSLo /usr/local/bin/mc https://dl.min.io/client/mc/release/linux-amd64/mc
chmod 0755 /usr/local/bin/mc

MC_CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "$MC_CONFIG_DIR"' EXIT

/usr/local/bin/mc --config-dir "$MC_CONFIG_DIR" alias set restoresrc \
    "$S3_SCHEME://$ETCD_S3_ENDPOINT" \
    "$ETCD_S3_ACCESS_KEY" "$ETCD_S3_SECRET_KEY"
/usr/local/bin/mc --config-dir "$MC_CONFIG_DIR" cp \
    "restoresrc/$ETCD_S3_BUCKET/$ETCD_S3_FOLDER/$SNAPSHOT_BASENAME" \
    "$SNAPSHOTS_DIR/"
```

Credentials live in `$MC_CONFIG_DIR` (a per-run `mktemp -d`) so they never
land in `/root/.mc/config.json`, and a `trap '...' EXIT` shreds the
directory even if subsequent `k3s --cluster-reset` aborts under
`set -e`.

`mc` is invoked **without** `--etcd-s3` on the subsequent `k3s` command —
k3s sees a normal local path and stays out of its broken S3 code path
entirely.

## Consequences

- Single-binary, ~25 MB download. Hetzner egress is free within the same
  network, but `dl.min.io` is external; expect ~1-2 s on a healthy
  connection.
- Credentials are confined to a per-run tempdir. A separate ADR could
  argue for moving them out of cloud-init `user_data` entirely (e.g., to
  a one-shot signed S3 URL embedded by the workflow), but that adds a
  workflow-side signing step and changes the trust boundary minimally.
  Inline + tempdir is the current trade-off.
- Adds an external dependency on `dl.min.io` reachability during cloud-
  init. If MinIO's mirror goes down, restore fails. Acceptable as a
  trade-off vs. carrying our own mirror; the failure mode is loud and
  immediately diagnosable.
- We continue to use k3s' built-in S3 snapshot **upload** path for routine
  cron snapshots (driven by the in-cluster Secret). It is only the
  restore-time download that we replaced.
