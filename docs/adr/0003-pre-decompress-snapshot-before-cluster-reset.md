# ADR-0003: Pre-decompress snapshot before `--cluster-reset-restore-path`

## Status

Accepted

## Context

The first attempt at S3 restore on k3s `v1.35.3+k3s1` failed with:

```
"Decompressing etcd snapshot file: /var/lib/rancher/k3s/server/db/snapshots/etcd-snapshot-<...>.zip"
"Error: starting kubernetes: failed to start cluster: start managed database:
 open /var/lib/rancher/k3s/server/db/snapshots/var/lib/rancher/k3s/server/db/snapshots/etcd-snapshot-<...>.zip: no such file or directory"
```

The path is **doubled** because of this code in
[`pkg/etcd/snapshot.go::decompressSnapshot`](https://github.com/k3s-io/k3s/blob/master/pkg/etcd/snapshot.go):

```go
func (e *ETCD) decompressSnapshot(snapshotDir, snapshotFilename string) (unzipPath string, err error) {
    snapshotPath := filepath.Join(snapshotDir, snapshotFilename)
    unzipPath = strings.TrimSuffix(snapshotPath, snapshot.CompressedExtension)
    ...
}
```

Go's `filepath.Join` does not strip a leading slash from an absolute second
arg — `Join("/a/b", "/c/d") == "/a/b/c/d"`. The caller in
[`pkg/etcd/etcd.go::Restore`](https://github.com/k3s-io/k3s/blob/master/pkg/etcd/etcd.go)
passes `e.config.ClusterResetRestorePath` (already absolute) as the
`snapshotFilename` argument:

```go
if strings.HasSuffix(e.config.ClusterResetRestorePath, snapshot.CompressedExtension) {
    decompressSnapshot, err := e.decompressSnapshot(dir, e.config.ClusterResetRestorePath)
    ...
    restorePath = decompressSnapshot   // ← doubled
} else {
    restorePath = e.config.ClusterResetRestorePath   // ← used verbatim, no bug
}
```

The bug only fires when `ClusterResetRestorePath` ends in `.zip` (k3s'
compressed-snapshot extension). The `else` branch handles uncompressed
paths verbatim with no join.

The "basename instead of abs path" alternative was tried and produced a
different failure: k3s `chdir`'s during its data-dir setup before the
`os.Stat`, so the basename couldn't be resolved relative to the snapshots
dir. The decompressor and the post-decompression loader use the path
differently in 1.35.x, and there is no single value that satisfies both.

## Decision

In the cloud-init restore branch, after downloading the snapshot from S3 to
`/var/lib/rancher/k3s/server/db/snapshots/<name>.zip`, run `unzip -o "$SNAP_ZIP"
-d "$SNAPSHOTS_DIR"` to produce `<name>` (without `.zip`). Pass the **absolute
path of the uncompressed file** to `--cluster-reset-restore-path`.

```bash
case "$SNAPSHOT_BASENAME" in
    *.zip)
        unzip -o "$SNAP_ZIP" -d "$SNAPSHOTS_DIR" >>"$LOG" 2>&1
        SNAP_RESTORE="$SNAPSHOTS_DIR/${SNAPSHOT_BASENAME%.zip}"
        ;;
    *)
        SNAP_RESTORE="$SNAP_ZIP"
        ;;
esac

/usr/local/bin/k3s server \
  --cluster-reset \
  --cluster-reset-restore-path="$SNAP_RESTORE" \
  ...
```

This routes through the safe `else` branch of `Restore()`, which uses the
path verbatim with no `filepath.Join`. `unzip` is added to the apt package
list in cloud-init.

## Consequences

- Restore works on k3s `v1.35.3+k3s1`. Verified end-to-end against a real
  snapshot in May 2026: 22 MB etcd data loaded, defrag completed, original
  cluster CA preserved.
- The fix is upstream-bug-specific. If k3s fixes `decompressSnapshot` to
  detect absolute paths (likely a one-line patch), this ADR's logic still
  works but becomes unnecessary. Revisit on k3s upgrade.
- Adds an `unzip` package dependency to cloud-init, ~200 KB on disk.
- The decompressed `.db` snapshot is left in
  `/var/lib/rancher/k3s/server/db/snapshots/` after restore. k3s prunes it
  on the normal snapshot retention cron.
