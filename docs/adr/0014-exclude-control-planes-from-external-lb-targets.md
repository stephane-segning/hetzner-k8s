# ADR-0014: Exclude control-plane nodes from external LoadBalancer target pools

## Status

Accepted

## Context

Hetzner CCM registers Kubernetes nodes as targets for any
`Service.type=LoadBalancer` (the Traefik / core-gateway ingress LB). By
default that includes the control-plane nodes.

Two problems with CPs in the ingress target pool:

1. **Control planes shouldn't serve ingress traffic.** They run cluster
   operators and the API; mixing ingress data-path load onto them is
   undesirable.
2. **A single bad CP target fails the *entire* LB sync (observed in prod).**
   After a control plane was recreated, its old `providerID`
   (`hcloud://127562844`) went stale. Hetzner CCM's reconcile then failed
   for the whole LoadBalancer:

   ```
   ReconcileHCLBTargets: ... cloud target was not found
   resolve_cloud_private_targets_error
   ```

   Because the reconcile is all-or-nothing, the Service never received an
   address — the ingress LB was effectively down until the bad target was
   removed. Excluding CPs removes this failure mode entirely; the
   core-gateway ingress LB provisioned immediately once the labels were
   applied.

Kubernetes has a standard node label for this:
`node.kubernetes.io/exclude-from-external-load-balancers`. CCM honors it
and registers only the unlabelled (worker) nodes.

### Why it can't be a k3s `--node-label`

kubelet runs under **NodeRestriction**, which forbids a node from
self-applying labels in the `node.kubernetes.io/*` (and `kubernetes.io/*`)
namespaces. So k3s `--node-label node.kubernetes.io/exclude-...` is
rejected — the label must be applied post-bootstrap with an admin
credential via `kubectl label`.

## Decision

Add a `label_loadbalancer_nodes` step to
`bootstrap/scripts/install-platform.sh`, run **before** the CCM/Traefik
install so the very first LB reconcile already targets workers only:

```bash
kubectl label nodes -l node-role.kubernetes.io/control-plane \
    node.kubernetes.io/exclude-from-external-load-balancers="" --overwrite
```

Selector-based and `--overwrite`, so it is idempotent across runs and
covers any number of control planes. Documented in `DECISIONS.md → Load
Balancer`.

## Consequences

- The ingress LB targets workers only; a recreated/unhealthy CP can no
  longer take down the whole `Service.type=LoadBalancer` sync.
- The label is applied by **Platform Up** (the script), not by Terraform
  or k3s. A control plane that joins *after* a Platform Up run will not
  carry the label until Platform Up is run again. Re-running Platform Up
  is the supported way to re-assert it; it's idempotent.
- This is an in-cluster (Kubernetes) concern layered on top of the
  CCM-owns-ingress-LB model (DECISIONS.md). It does not touch the
  Terraform-managed API LB on `:6443`, whose targets are the control
  planes by design.
- **Trap:** if you ever see a `Service.type=LoadBalancer` stuck without an
  address and the CCM logs show `cloud target was not found` /
  `resolve_cloud_private_targets_error`, suspect a stale CP target (or a
  node with a stale `providerID`) poisoning the all-or-nothing reconcile.
  Confirm the CP exclusion label is present on all control planes; re-run
  Platform Up if not.
