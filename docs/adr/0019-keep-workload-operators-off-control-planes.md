# ADR-0019: Keep workload operators off the control planes (and which ones must stay)

## Status

Accepted (2026-07-25). Companion to **ADR-0018**.

## Context

The control planes have carried
`node-role.kubernetes.io/control-plane=true:NoSchedule` since the beginning —
set in all three k3s server blocks in `bootstrap/cloud-init/node.yaml`. On
2026-07-25 the taint was verified present and **un-drifted** on all three CPs.

Nevertheless, **8 Deployment-owned pods were running on control planes**. A
`NoSchedule` taint only repels pods that do not tolerate it, and several
upstream charts ship a blanket
`key: node-role.kubernetes.io/control-plane, operator: Exists` toleration.
The taint was doing its job; the charts were opting out.

Measured footprint at the time:

| Pod | Node | Memory | Chart owned by |
|---|---|---|---|
| `hcloud-csi-controller` | cp-3 | **222 MiB** | this repo |
| `cnpg-cloudnative-pg` | cp-3 | 87 MiB | this repo (but see drift note) |
| `external-secrets` (+webhook) | cp-2 | 191 MiB | elsewhere |
| `cert-manager` cainjector + webhook | cp-2 | 176 MiB | elsewhere |
| `opentelemetry-operator` | cp-2 | 83 MiB | elsewhere |
| `cilium-operator` | cp-2 | 42 MiB | this repo — **must stay** |

## Decision

Workload operators do not belong on control planes. Where this repo owns the
chart values, drop the control-plane toleration so the existing taint is
effective.

Concretely: `platform/helm-values/hcloud-csi-values.yaml` sets
`controller.tolerations: []`.

### What must KEEP tolerating the taint (do not "clean these up")

This is the load-bearing half of the decision:

- **`cilium-operator`** — it also tolerates `node.kubernetes.io/not-ready`,
  `node.cloudprovider.kubernetes.io/uninitialized`, and
  `node.cilium.io/agent-not-ready`, because it must run *during a cold
  bootstrap, before any node is Ready*. Force it off the CPs and a fresh
  cluster deadlocks: no CNI → no node ever becomes Ready → no worker ever
  exists for the operator to land on.
- **Hetzner CCM** — must run before it has removed the
  `node.cloudprovider.kubernetes.io/uninitialized` taint from workers. Same
  bootstrap-ordering argument (see also ADR-0014).
- **`hcloud-csi-node` DaemonSet** — a DaemonSet, node-local by definition.
- **`coredns`** — cluster DNS; k3s-managed and small.

The rule of thumb: *bootstrap-critical or node-local components tolerate the
taint; everything else does not.*

## Consequences

- ~222 MiB returned to cp-3. After ADR-0018 the CPs have 4+ GB free, so this
  is **hygiene, not a fix** — it was explicitly *not* sufficient on its own to
  solve the flapping (ADR-0018 rejects it as the primary remedy).
- Takes effect when Argo CD (home cluster) syncs `hetzner-helm`, or on the
  next `platform-up.yml` run. The CSI controller pod will be rescheduled onto
  a worker; volume attach/detach pauses briefly during that rollout.
- ⚠️ **Out of scope here:** `external-secrets`, `cert-manager`, and
  `opentelemetry-operator` (~450 MiB combined) are not managed from this repo.
  Their tolerations must be fixed wherever their Argo Application lives.
- ⚠️ **Known drift discovered while writing this ADR:**
  `platform/helm-values/cnpg-values.yaml` already declares `tolerations: []`,
  `resources.requests.memory: 256Mi`, and `monitoring.podMonitorEnabled:
  true` — but the *live* cnpg operator runs `requests 100Mi / limits 200Mi`,
  has the control-plane toleration, and has **no PodMonitor**. That means this
  values file is **not being applied** (the `cnpg` Argo Application is not
  syncing it). Fixing cnpg's placement requires fixing that sync first;
  editing the values file alone changes nothing.
