# ADR-0011: Pass `--node-ip` and `--advertise-address` to cluster-reset

## Status

Accepted

## Context

After the cluster-reset code path stabilized (ADR-0003, ADR-0009,
ADR-0010), the restore produced a healthy single-node etcd with the
restored data. But `k3s.service` then refused to start with:

```
"Failed to test etcd connection: this server is not a member of the etcd cluster.
 Found [ssegning-hetzner-k3s-cp-1-abfc7b38=https://159.69.22.206:2380 ...],
 expect: ssegning-hetzner-k3s-cp-1-abfc7b38=https://10.0.0.10:2380"
```

The restored etcd member list recorded cp-1's peer URL as
`https://159.69.22.206:2380` — the **public** IP — even though
`/etc/systemd/system/k3s.service` advertised `--node-ip=10.0.0.10` (the
private IP). On startup, etcd compared the configured peer URL against
the stored member list, found a mismatch, and refused to join.

Root cause: the `--cluster-reset` invocation runs as a **separate
process** from the eventual systemd-managed `k3s.service`. It does not
inherit the `--node-ip` / `--advertise-address` flags written into the
systemd unit by the install. Cluster-reset only reads:

- CLI args we pass
- `/etc/rancher/k3s/config.yaml`

Neither path carries the private IP. k3s defaults to the default-route
interface (eth0, public on Hetzner), and that's what got persisted to the
restored member list when cluster-reset's brief etcd run wrote its
membership record.

## Decision

Pass `--node-ip` and `--advertise-address` to the cluster-reset CLI,
matching what the systemd unit will use:

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

The restored etcd member list now records `https://10.0.0.10:2380` for
cp-1's peer URL — same value `systemctl start k3s` will use moments
later. No mismatch, k3s starts cleanly.

## Consequences

- The bootstrap CP comes up cleanly after cluster-reset, no manual
  intervention needed to fix the peer URL.
- Any flag that affects etcd member configuration (`--node-ip`,
  `--advertise-address`, possibly `--cluster-cidr`/`--service-cidr` in
  the future) needs to be passed in *both* the install invocation
  (writes to the systemd unit) and the cluster-reset invocation. The
  cloud-init script does both side-by-side; this is documented inline
  with a comment.
- The lesson generalizes: any one-shot k3s server command outside the
  systemd unit needs the relevant network flags. If we add a new flag
  to the install in the future, also add it to the cluster-reset call.
