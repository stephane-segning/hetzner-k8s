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

- Derives the **exact set of node names** Terraform manages from
  `cluster_name` and the counts — `${cluster}-cp-1..N`,
  `${cluster}-worker-1..M` (the 1-indexed `format()` in
  `terraform/envs/prod/locals.tf`).
- Authenticates with the existing `REMOTE_CLUSTER_KUBECONFIG_B64` secret —
  the one the Verify Etcd Backups workflow already uses. The cluster CA is
  preserved across an etcd restore (it lives in the snapshot), so this
  kubeconfig stays valid through restore; it is only stale after a
  from-scratch rebuild with a brand-new CA (break-glass, rare).
- Polls until **every expected node is `Ready` with a live kubelet lease**,
  within the same time budget as the `/livez` wait (10 min routine, 15 min
  restore). On timeout it prints the unsatisfied node list and
  `kubectl get nodes -o wide`, then fails the run loudly, pointing at the
  `replace_nodes` recovery path.

Design choices (several refined in review):

- **Check the exact expected name-set, not "any N Ready nodes."** A leftover
  Node object from a scale-down or a replace can sit `Ready=True` briefly.
  Counting `Ready >= EXPECTED` over all nodes would let such a ghost fill the
  count while a genuinely-expected node is missing or NotReady. Keying on the
  deterministic Terraform names removes that ambiguity, so equality on the
  expected set is exactly right.
- **Liveness from the node Lease, not the Ready condition's heartbeat.**
  With NodeLease enabled the kubelet only re-posts an *unchanged* NodeStatus
  every `nodeStatusReportFrequency` (default **5 min**), so
  `Ready.lastHeartbeatTime` can be minutes stale on a perfectly healthy node
  — an earlier heartbeat-freshness attempt would have failed routine runs.
  The Lease `renewTime` (`kube-node-lease`) refreshes every ~10s, so
  `LEASE_FRESH=45s` cleanly separates a live kubelet from a dead one. This
  also defends the `replace_nodes` case: a recreated node reuses its Node
  object (same name) but its Lease stops renewing when the old kubelet dies,
  so a stale `Ready=True` cannot satisfy the gate before the new VM rejoins.
- **Pre-CNI degradation, fail-closed.** A from-scratch bootstrap starts k3s
  with `--flannel-backend=none`; nodes stay `NotReady` until Platform Up
  installs Cilium. The gate degrades to a **registration-only** check (the
  expected set merely exists) *only* when the Cilium DaemonSet lookup returns
  a definite `NotFound`. Transient/RBAC errors keep full Ready enforcement
  on, so a routine cluster cannot silently downgrade because of one flaky
  `kubectl` call.
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
