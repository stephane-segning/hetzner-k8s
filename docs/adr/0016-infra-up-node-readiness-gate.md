# ADR-0016: Infra Up verifies node readiness, not just API `/livez`

## Status

Accepted

> Note: ADR-0014 and ADR-0015 are reserved by an in-flight docs PR; this
> ADR is numbered 0016 to avoid colliding with them.

## Context

Infra Up's only success gate was the `/livez` probe added in ADR-0008: it
polls the API load balancer until the apiserver returns `200/401/403`.
That proves the **control plane** is reachable — it says nothing about
**workers**.

This bit us in production. A worker (`worker-3`) hard-hung — the host still
answered ping and TCP, but `sshd` and kubelet were wedged and kubelet
stopped posting node status, so the node went `NotReady`. Separately, the
operator scaled `worker_count` up; Terraform created the new worker, it
joined fine, and Infra Up reported **success in 1m41s** — green over a
cluster that was actually one usable worker short. The `/livez` gate
couldn't see it, and there was no other check. The failure was invisible
until someone ran `kubectl get nodes` by hand — exactly the manual toil the
operating model forbids.

Two distinct gaps:

1. A pre-existing node going `NotReady` is never surfaced by a routine run.
2. A newly added worker's join is unverified — Terraform returns as soon as
   the VM is created, long before cloud-init finishes and the node joins.

## Decision

Add a **node-readiness gate** to Infra Up, after the `/livez` wait and
before the endpoint summary. It:

- Computes `EXPECTED = control_plane_count + worker_count` from the same
  `TF_VAR_*` the job already exports.
- Authenticates with the existing `REMOTE_CLUSTER_KUBECONFIG_B64` secret —
  the one the Verify Etcd Backups workflow already uses. The cluster CA is
  preserved across an etcd restore (it lives in the snapshot), so this
  kubeconfig stays valid through restore; it is only stale after a
  from-scratch rebuild with a brand-new CA (break-glass, rare).
- Polls `kubectl get nodes` until **at least `EXPECTED` nodes are *freshly*
  `Ready`**, within the same time budget as the `/livez` wait (10 min
  routine, 15 min restore). On timeout it prints `kubectl get nodes -o wide`
  and fails the run loudly, pointing at the `replace_nodes` recovery path.

Design choices:

- **`Ready >= EXPECTED`, not `== EXPECTED`.** Exact equality on the *Ready*
  count would fail when extra `Ready` nodes exist transiently — e.g. a
  scale-down or rolling replace where an old node still reports `Ready`
  before it is removed. (A stale *NotReady* ghost would not break an
  `==` on the Ready count, but it *would* break a "require all registered
  nodes Ready" check — which is the stricter variant we also reject.) `>=`
  asserts we have at least the capacity we asked for; the step still reports
  any extra NotReady/stale objects so they get cleaned up.
- **Count only *freshly* Ready nodes** (Ready condition `lastHeartbeatTime`
  within `FRESH_SECONDS=120`). `replace_nodes` recreates a node under the
  *same* Node-object name; that object can keep a stale `Ready=True` until
  the node controller marks it `Unknown`. Since `/livez` returns instantly
  on an already-running cluster, a plain Ready check could pass on the old
  status before the replacement VM rejoins. Requiring a recent heartbeat
  means only a live kubelet satisfies the gate.
- **Pre-CNI degradation.** A from-scratch bootstrap starts k3s with
  `--flannel-backend=none`; nodes stay `NotReady` until Platform Up installs
  Cilium. If no Cilium DaemonSet is found (checked with retries; defaults to
  "present" so routine runs always enforce Ready), the gate degrades to a
  **registration-only** check (`registered >= EXPECTED`) with a loud warning,
  rather than deadlocking that supported window.
- **Bounded kubectl calls.** Every `kubectl` runs with
  `--request-timeout=15s`. The default is `0` (no timeout), so a stale or
  blackholed endpoint would block past `DEADLINE` — the loop only re-checks
  the clock after kubectl returns — and the job would hang instead of
  failing with diagnostics.
- **Skip-with-loud-warning when the kubeconfig secret is absent**, rather
  than hard-fail. This keeps Infra Up usable in an environment that hasn't
  configured the secret while still making the gap visible (`::warning::`
  + step summary). Setting the secret upgrades it to a hard gate.

## Consequences

- A `NotReady` or never-joined worker now turns Infra Up **red** instead of
  green. The operator learns from the run, not from a manual `kubectl`.
- New-worker joins are verified end-to-end: the run does not succeed until
  the new node is actually `Ready`.
- The gate composes with the sibling `replace_nodes` Infra Up input: a
  failed gate names the exact recovery command (`replace_nodes=<key>`), and
  recovery happens through the supported GH-Actions surface.
- Infra Up now depends on `REMOTE_CLUSTER_KUBECONFIG_B64` for the *full*
  guarantee. Without it the run still completes but prints a visible
  warning that node readiness was not verified.
- On a from-scratch rebuild (new CA) the kubeconfig is stale and the gate
  would fail; that path is deliberate break-glass work where the operator
  refreshes the secret as part of standing the cluster back up.
