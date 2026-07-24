# Runbook — Add a GPU node (manual, off-cloud Robot server)

## Operating model (read first)

These GPU workers are Hetzner **Robot dedicated servers**, not cloud VMs. They are
joined **by hand** — no Terraform, no Ansible, no Infra Up. They are **pets**:
invisible to Terraform state, the Infra Up node-readiness gate, and `replace_nodes`
recovery. Nothing in `.github/workflows/` knows they exist. If one dies, you re-run
this runbook; you do **not** run Infra Up.

Networking: each box attaches to the cloud private network via **Hetzner vSwitch**
(VLAN 4000, MTU 1400), getting a private IP in a dedicated subnet `10.0.1.0/24`
(gateway `10.0.1.1`). The cluster stays Cilium VXLAN; the GPU node participates in
pod networking over the vSwitch. Its public NIC is directly on the internet (unlike
cloud nodes behind the hcloud firewall) — lock it down locally (Phase 2).

## Why a Robot node needs three "markers"

hcloud's cloud components assume every node is a cloud VM. A Robot node must carry
these or those components break it:

| Marker | Set via | Prevents |
|---|---|---|
| foreign providerID `baremetal://<host>` | `--kubelet-arg=provider-id=` | CCM `cloud-node-lifecycle` **deleting the node** (~3 s after registration: "does not exist in the cloud provider") — a foreign prefix makes the CCM's lookup *error* instead of returning NotFound, so it leaves the node alone |
| `node.kubernetes.io/exclude-from-external-load-balancers=true` | `--node-label` | CCM adding it to ingress LB target pools (`UnknownProviderIDPrefix`, ADR-0014 poisoning risk) |
| `instance.hetzner.cloud/is-root-server=true` | `--node-label` | `hcloud-csi-node` DaemonSet crashlooping (its driver needs the cloud metadata service `169.254.169.254`, absent on Robot); the chart's built-in affinity excludes nodes with this label |

Also: **do NOT** pass `--cloud-provider=external` (it would strand the node with an
unclearable `node.cloudprovider.kubernetes.io/uninitialized` taint — hcloud-ccm #796).

## Prerequisites

- The vSwitch (VLAN 4000) exists in Robot with a connected cloud subnet
  `10.0.1.0/24`. For a new box, just **attach it to the same vSwitch** in Robot.
- Pick:
  - `<HOST>` — unique, DNS-safe hostname, e.g. `hetzner-k8s-gpu-3`
  - `<GPUIP>` — a free IP in `10.0.1.0/24`, not `.1` (gateway); e.g. `10.0.1.5`
  - `<NIC>` — the box's physical NIC (`ip -br link`; has been `enp4s0`)
- `<TOKEN>` — a join token. Prefer a non-expiring one: `k3s token create --ttl 0`
  on a control plane. (`k3s token create` defaults to a **24 h TTL** — an expired
  token gives an endless "Node authorization rejected" loop.)
- k3s version pin: `v1.35.3+k3s1`.
- The `nvidia` RuntimeClass and the `nvidia-device-plugin` DaemonSet already exist
  cluster-wide — **do not** re-create them. The device plugin auto-schedules once
  the node has `nvidia.com/gpu.present=true`.

## Procedure

### Phase 1 — vSwitch networking (Robot UI + box)

Attach the server to the vSwitch in Robot, then on the box:

```bash
apt-get update && apt-get install -y vlan && modprobe 8021q
cat >/etc/network/interfaces.d/vswitch <<EOF
auto <NIC>.4000
iface <NIC>.4000 inet static
  address <GPUIP>
  netmask 255.255.255.0
  vlan-raw-device <NIC>
  mtu 1400
  up   ip route add 10.0.0.0/16 via 10.0.1.1 dev <NIC>.4000
  down ip route del 10.0.0.0/16 via 10.0.1.1 dev <NIC>.4000
EOF
ifup <NIC>.4000
ping -c3 10.0.0.10 && curl -sk https://10.0.0.10:6443/healthz; echo
```

Gate: ping replies and healthz returns `401`/`ok` before continuing. If not, stop —
nothing downstream works.

### Phase 2 — host prep + lock the public NIC

```bash
hostnamectl set-hostname <HOST> && timedatectl set-timezone UTC
grep -q <HOST> /etc/hosts || echo "127.0.1.1 <HOST>" >> /etc/hosts
swapoff -a && sed -i.bak '/\sswap\s/s/^/# /' /etc/fstab
printf 'overlay\nbr_netfilter\n' >/etc/modules-load.d/k8s.conf && modprobe overlay && modprobe br_netfilter
printf 'net.bridge.bridge-nf-call-iptables=1\nnet.bridge.bridge-nf-call-ip6tables=1\nnet.ipv4.ip_forward=1\n' >/etc/sysctl.d/90-kubernetes.conf && sysctl --system >/dev/null
```

Minimal public firewall (allow SSH + established from the internet, everything on
the vSwitch VLAN; k3s dials outbound and needs no public inbound):

```bash
apt-get install -y nftables
cat >/etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif "lo" accept
    iifname "<NIC>.4000" accept
    ip saddr 10.0.0.0/16 accept
    tcp dport 22 accept
    ip protocol icmp accept
  }
  chain forward { type filter hook forward priority 0; policy accept; }
  chain output  { type filter hook output priority 0; policy accept; }
}
EOF
systemctl enable --now nftables && nft -f /etc/nftables.conf
```

### Phase 3 — GPU driver + container runtime (before k3s)

Enable Debian 13 `non-free` (the default `Components:` line ends in
`non-free-firmware`, so a naive `s/main$/…/` no-ops), then install the driver
**including `libcuda1`** — the piece `nvidia-driver` omits and the whole reason CUDA
fails while `nvidia-smi` works:

```bash
sed -i 's/Components: main non-free-firmware/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources
apt-get update && apt-get install -y linux-headers-amd64 nvidia-driver nvidia-smi libcuda1 firmware-misc-nonfree nvidia-persistenced
systemctl enable --now nvidia-persistenced
modprobe nvidia
nvidia-smi | grep -i 'CUDA Version'    # MUST show a version (e.g. 12.4), NOT "N/A"
```

If `nvidia-smi` fails, reboot once and retry. Then the container toolkit and the
**legacy runtime mode** (auto mode picks CDI, which mismatches the device plugin's
env-var strategy → 0 devices):

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' >/etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update && apt-get install -y nvidia-container-toolkit
sed -i 's/^mode = "auto"/mode = "legacy"/' /etc/nvidia-container-runtime/config.toml
which nvidia-container-runtime         # must print a path BEFORE k3s installs
```

> Do **not** run `nvidia-ctk runtime configure` — it edits the system containerd,
> which k3s does not use. k3s auto-detects the runtime binary at install and wires
> its own containerd.

### Phase 4 — join k3s

```bash
mkdir -p /etc/rancher/node && openssl rand -hex 16 > /etc/rancher/node/password && chmod 600 /etc/rancher/node/password
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="v1.35.3+k3s1" \
  K3S_URL="https://10.0.0.10:6443" \
  K3S_TOKEN="<TOKEN>" \
  sh -s - agent \
    --node-ip <GPUIP> \
    --kubelet-arg=provider-id=baremetal://<HOST> \
    --node-label nvidia.com/gpu.present=true \
    --node-label node.kubernetes.io/exclude-from-external-load-balancers=true \
    --node-label instance.hetzner.cloud/is-root-server=true \
    --node-taint nvidia.com/gpu=true:NoSchedule
```

Must be exactly right: **no `--cloud-provider=external`**, **`provider-id=baremetal://<HOST>`**,
and **no `node-role.kubernetes.io/gpu` label here** (kubelet rejects restricted
labels and crashes — apply it from a CP in Phase 5). A fresh box bootstraps clean on
the first try; if you ever *retry*, `rm -rf /var/lib/rancher/k3s/agent` first (a
stale client cert forces the node-identity path and an endless 401 loop).

### Phase 5 — from a control plane

```bash
kubectl label node <HOST> node-role.kubernetes.io/gpu= --overwrite
kubectl get node <HOST> -o wide                                              # Ready, providerID baremetal://<HOST>
kubectl get node <HOST> -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'   # -> 1
```

The device plugin auto-lands and `nvidia.com/gpu` goes to `1`. Confirm CUDA
end-to-end (allocatable alone only proves the privileged plugin sees the card):

```bash
kubectl run gpu-smoke --rm -it --restart=Never -n default \
  --overrides='{"spec":{"runtimeClassName":"nvidia","nodeName":"<HOST>","tolerations":[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]}}' \
  --image=nvcr.io/nvidia/k8s/cuda-sample:nbody -- nbody -gpu -benchmark -numbodies=131072
```

Expect a GFLOP/s figure (RTX 4000 SFF Ada ≈ 9.7 TFLOP/s single-precision).

## Storage & ingress (workload side)

- **No hcloud block-volume PVCs on GPU nodes** — the CSI node plugin is excluded, so
  the attach/mount path doesn't exist there. Store models in **S3** (source of truth)
  and cache on the node's **local NVMe** (standalone `local-path-provisioner` scoped
  to GPU nodes, or a `hostPath`); an init container `mc cp`s from S3 into the cache.
  Avoid pure-S3-to-`emptyDir` for large models (re-downloads every restart).
- **Ingress**: `client → hcloud ingress LB → Traefik (cloud node) → ClusterIP Service
  → LLM pod on the GPU node (Cilium VXLAN)`. The GPU node needs no LB membership and
  doesn't run Traefik. Expose with a normal `Service` + `IngressRoute`/`Ingress`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Agent loops `Node authorization rejected` / `ContentLength=… with Body length 0` | Stale client cert in `/var/lib/rancher/k3s/agent` forces the node-identity path; the retry-without-cert path is broken | `systemctl stop k3s-agent && rm -rf /var/lib/rancher/k3s/agent && systemctl start k3s-agent` (forces cert-free password bootstrap) |
| Same loop, and token was `k3s token create`d | Default 24 h TTL expired | Mint `k3s token create --ttl 0` (or use `/var/lib/rancher/k3s/server/node-token`) |
| CP log: `unable to verify node identity: nodes "<host>" not found` | Agent presented a cert but the Node object doesn't exist yet | Same cert wipe as above; ensure the node isn't being deleted (next row) |
| kubelet crashes: `unknown 'kubernetes.io' labels … [node-role.kubernetes.io/gpu]` | kubelet forbids self-setting restricted labels | Drop `node-role` from `--node-label`; apply it from a CP via `kubectl label` |
| Node registers then vanishes; event `Deleting node … because it does not exist in the cloud provider` | CCM `cloud-node-lifecycle` can't find the Robot box in hcloud | Set `--kubelet-arg=provider-id=baremetal://<host>` and rejoin cert-free |
| `hcloud-csi-node` pod CrashLoopBackOff on the GPU node (`metadata service … context deadline exceeded`) | CSI driver needs cloud metadata `169.254.169.254`, absent on Robot | Label the node `instance.hetzner.cloud/is-root-server=true`, delete the stuck pod |
| `nvidia-smi: command not found` after driver install | `nvidia-smi` is a separate Debian package | `apt-get install -y nvidia-smi` |
| `nvidia-driver` package "not found" | `non-free` not actually enabled (line ends in `non-free-firmware`) | Fix `Components:` to include `contrib non-free`, `apt-get update` |
| Pod: `Error: only 0 Devices available` but `nvidia-smi` works | runtime in `auto` mode picked CDI, mismatched with device-plugin env-var strategy | `mode = "legacy"` in `/etc/nvidia-container-runtime/config.toml` |
| CUDA sees 0 devices; `nvidia-smi` shows `CUDA Version: N/A` | `libcuda.so.1` missing (Debian `nvidia-driver` omits it) | `apt-get install -y libcuda1`, then re-create the pod |
| Large cross-node transfers to GPU pods stall | vSwitch MTU 1400 vs cloud 1450 asymmetry over VXLAN | Pin Cilium `MTU: 1400` cluster-wide (Platform Up) |
| Benign, ignore | CCM `FailedToCreateRoute` for the node (foreign providerID) | None — Cilium VXLAN handles pod routing |

## Reboot persistence

All of the above survives reboot: the vSwitch interface (`/etc/network/interfaces.d`),
legacy mode + `libcuda1` (on-disk), the systemd unit with the providerID/labels, and
the Node object (so the agent re-registers with its client cert without re-bootstrap).
`nvidia-persistenced` keeps the driver initialized so `/dev/nvidia*` exist at boot.
After a kernel/driver upgrade, re-verify `nvidia-smi` shows a CUDA version and re-run
the Phase 5 smoke test.

## See also

- `docs/adr/` — consider an ADR for the foreign-providerID / manual-pet pattern.
- `AGENTS.md`, `DECISIONS.md` — operating-model constraints.
