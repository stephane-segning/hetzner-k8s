# ADR-0005: Bring up the Hetzner private NIC explicitly in cloud-init

## Status

Accepted

## Context

The Hetzner Cloud provider's `hcloud_server` resource attaches a server to
a private network via the embedded `network {}` block. The attachment
happens via the Hetzner API as part of server creation and typically
completes within a few seconds. The OS sees a second NIC (`enp7s0` after
udev rename) with a MAC matching the Hetzner metadata service's record
for the network.

Cloud-init's Hetzner datasource normally writes a netplan config covering
both NICs. However, when the network attachment **races** with cloud-init's
network rendering stage (faster server boot or slightly slower API
attachment), netplan is written with only `eth0` (the public NIC). The
private NIC exists at `ip link` level but is `DOWN` and has no IP. k3s
then fails to bind `--node-ip=10.0.0.X` for either etcd peer (`:2380`) or
API serving, and the node loops on `bind: cannot assign requested address`.

Observed on every cp-1 replacement in the May 2026 restore work; the
race resolved differently across CPs (workers won the race, CPs lost),
making it look like an unrelated bug at first.

Comparison from cp-01 (broken) vs worker-01 (working) `/etc/netplan/`:

```yaml
# worker-01 — correct
network:
  version: 2
  ethernets:
    enp7s0:
      match:
        macaddress: "86:00:00:57:30:69"
      dhcp4: true
      set-name: "enp7s0"
    eth0: { ... }

# cp-01 — incorrect (only eth0 in netplan, enp7s0 stays DOWN)
network:
  version: 2
  ethernets:
    eth0: { ... }
```

## Decision

Add an `ensure_private_nic` function at the very top of
`/opt/k3s-bootstrap.sh` in `bootstrap/cloud-init/node.yaml`. It runs before
the swap/sysctl prep and before any k3s install. The function:

1. Returns immediately if the expected private IP (`NODE_PRIVATE_IP` from
   the cloud-init template) is already bound to a local interface.
2. Polls `ip link show` for up to 120 s for any interface that is not
   `lo`, `eth0`, or a known virtual interface (`docker.*`, `cilium.*`,
   `veth.*`, `cni.*`, `kube-.*`, `flannel.*`). The grep stage is wrapped
   `{ grep -vE '...' || true; }` to survive `set -o pipefail` when no
   matches yet — important on early attempts during the very race we
   are trying to handle.
3. Reads the NIC's MAC, writes a netplan config matching by MAC (built
   via `printf` to dodge the bash-heredoc / YAML-literal-block indent
   conflict — see ADR-XXXX in `lessons-learned`), `chmod 0600`, runs
   `netplan generate && netplan apply`.
4. Polls for the expected IP to appear; fails the bootstrap if it
   doesn't within 120 s.

The function is idempotent: re-running cloud-init on a node that already
has the private NIC up returns immediately. It's role-agnostic: applies to
both control planes and workers.

## Consequences

- The "private NIC missing" failure mode is self-healed on every boot. The
  node always comes up with the configured `10.0.0.X` private address bound
  and `k3s` can advertise it.
- We accept ownership of generating a netplan file the Hetzner datasource
  would normally write. If a future cloud-init version changes the file
  layout, our `60-private.yaml` may conflict; mitigation is matching by
  MAC, which is per-VM-unique.
- The function uses `printf` line-by-line to build the YAML to avoid the
  same heredoc/literal-block indent trap that bit us elsewhere in
  cloud-init.
- Workers from prior provisioning (before this ADR) that happened to win
  the race need no migration; the function detects the IP is already
  bound and returns immediately.
