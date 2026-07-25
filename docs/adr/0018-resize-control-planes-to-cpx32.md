# ADR-0018: Resize control planes CPX22 → CPX32 (memory, not CPU)

## Status

Accepted (2026-07-25). Supersedes the `CPX22` control-plane choice in
`DECISIONS.md → Server Types`.

## Context

Through July 2026 the control planes intermittently went `NotReady` in the
dashboard — **while `ssh` to the same node worked fine**. The monitoring
dashboard attributed it to CPU. That attribution was wrong, and acting on it
(buying vCPU, or re-tainting nodes) would not have fixed anything.

The June 2026 position had been "CP RAM pressure is known and accepted": the
symptom was a benign `k3s.service` exit `status=1` roughly every ~9 days,
self-restarted by systemd, quorum never at risk. **That premise stopped
holding.** By 2026-07-25 the failure mode had changed shape:

- `k3s-server` RSS grew **~1.95 GiB (Jun 27) → 2.46 GiB (Jul 25)** — ~64% of
  a 3.7 GiB box, with swap disabled.
- cp-2 had **zero** k3s restarts in 3 days, yet **all three CPs flapped
  `Ready`→`NotReady` within 32 hours**. So it was no longer "k3s dies and
  restarts"; the process stayed up and the *node* dropped out.

### What the measurements actually showed (cp-2)

| Signal | Reading | Conclusion |
|---|---|---|
| load avg | 0.25 on 2 vCPU | idle |
| **CPU steal** | **0.0 %** | no noisy neighbour |
| PSI `cpu` full | 0.00 | nothing ever stalls on CPU |
| `slow fdatasync` | 2× in 2 days | disk is fine |
| kernel OOM kills | 0 | not OOM-killed |
| `apply request took too long` | **5,463×** in 2 days | ⚠️ |
| `failed to send out heartbeat` | 49× + `leadership transfer failed` | ⚠️ |
| memory | 3,106 / 3,814 MB used, ~480 MB available | ⚠️ binding |

The slow-apply traces put the latency inside
`agreement among raft nodes before linearized reading` (168–296 ms), and the
requests timing out were **lease reads** (`/registry/leases/...`).

That yields the causal chain:

> memory exhaustion on a 3.7 GiB box → etcd/apiserver latency (raft agreement
> + GC pressure in the single all-in-one `k3s-server` process) → kubelet
> cannot renew its **Node Lease** inside the ~40 s grace period → node
> controller marks the node `NotReady` → **the machine is perfectly healthy,
> so SSH still works.**

`k3s-server` is one process (apiserver + embedded etcd + controller-manager +
scheduler). Its apiserver watch-cache scales with the number of API object
*kinds*, not pod count, and this cluster is CRD-heavy (Envoy Gateway, Envoy AI
Gateway, CNPG, Kuadrant/Authorino, Keycloak, Grafana/Mimir/Loki/Tempo). The
cluster simply outgrew its control plane.

### A hypothesis that was tested and rejected

An early theory was "the 1.1 GB etcd database can't stay in page cache." It is
wrong and is recorded here so nobody re-derives it: `du` of
`/var/lib/rancher/k3s/server/db` counts **WAL + snapshots**. The actual etcd
database is **54 MB**. Page-cache pressure on the DB was never the mechanism.

## Decision

Resize all three control planes to **CPX32** (4 vCPU / 8 GB / 160 GB) and make
`cpx32` the default `control_plane_server_type`.

Resize **in place**, not via node replacement. `server_type` is *not*
`ForceNew` in the hcloud Terraform provider — changing it calls
`Server.ChangeType()` (power off → resize → power on), so the server keeps its
ID. This avoids re-running cloud-init (ADR-0013), re-bootstrapping k3s, and
re-joining etcd. One node at a time; quorum holds at 2/3.

The extra 2 vCPU are incidental. **This is a memory decision.** Do not cite it
as precedent for buying CPU.

## Consequences

- Measured on cp-2 immediately after resize: `failed to send out heartbeat`
  **49 → 0**; `apply request took too long` **44 per 2.5 h → 16**; available
  memory **~480 MB → ~4,057 MB**.
- `k3s-server` RSS promptly expanded to ~2.80 GB. This is **expected** — Go
  grows its heap to fit available memory. Judge headroom, not RSS.
- **The default in `vars.tf` and all three workflows' `|| 'cpx22'` fallbacks
  had to change together.** Leaving them would make the next Infra Up rescale
  the CPs *back down* to 4 GB. If `TF_CONTROL_PLANE_SERVER_TYPE` is set as a
  GitHub repo variable, it must be updated too — it wins over the default.
- 🧨 **The rescale itself broke cp-1.** One of three identical nodes came back
  with an empty `/etc/fstab`, leaving `/` read-only and k3s crash-looping. See
  `docs/caveats-and-traps.md § 6.1` and the
  `docs/lessons-learned/2026-07-25-cp-rescale-empty-fstab.md` post-mortem
  before performing another rescale.
- Cost: the €110/month budget in arc42 § 10.5 was re-baselined to ~€185-190
  net. The CP resize is a small part of that; the dominant drivers were the
  April 2026 price rise and the 2→4 worker scale-up.

## Alternatives considered

- **Evict the operator pods squatting on the CPs.** Real but insufficient:
  worth ~300-400 MiB per CP against a 2.5 GB process on a 3.7 GiB box. Done
  anyway as hygiene where this repo controls the chart (ADR-0019).
- **Stay on CPX22 and cap the apiserver watch-cache / journald.** Treats the
  symptom; the growth trend (+0.5 GiB/month) would re-cross the threshold.
- **Add a 4th/5th control plane.** Increases etcd quorum cost and raft
  chatter — the opposite of what the raft-latency evidence called for.
- **CX32 (Intel) instead of CPX32 (AMD).** Possibly cheaper; not chosen
  because the CPX line was already in use and the resize path was proven.
