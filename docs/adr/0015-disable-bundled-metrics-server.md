# ADR-0015: Disable k3s's bundled metrics-server (platform GitOps owns it)

## Status

Accepted

## Context

k3s ships a bundled, single-replica `metrics-server` Deployment in
`kube-system`. The platform layer (the home-cluster ai-helm `charts/apps`)
deploys the upstream `kubernetes-sigs/metrics-server` chart with **HA (2
replicas)** and tuned kubelet args. Both want to own the same name,
`metrics-server`, in `kube-system`.

The collision is subtle and breaks metrics cluster-wide:

- The **bundled** Deployment uses pod labels `k8s-app: metrics-server`.
- The **chart's** Service uses selector `app.kubernetes.io/*`.
- The chart's Service therefore selects **no endpoints** (the running pods
  are the bundled ones with the wrong labels).
- The `v1beta1.metrics.k8s.io` APIService points at that Service, sees no
  backing endpoints, and goes `Available=False`.
- Result: `kubectl top` and HPA metrics break across the whole cluster.

## Decision

Disable the bundled metrics-server so the GitOps chart is the single
owner. Add `--disable metrics-server` to **every k3s server** invocation in
`bootstrap/cloud-init/node.yaml` — all three server blocks (fresh
`--cluster-init`, joining CP, and the restore-mode install). Agents take no
`--disable` flags. Documented in `DECISIONS.md → K3s metrics-server`.

## Consequences

- One owner for metrics-server (the platform chart). `kubectl top` and HPA
  work against the HA deployment.
- **⚠️ Trap — takes effect only on (re)provision.** `--disable` is an
  install/start-time k3s flag. Adding it to cloud-init affects nodes
  created or restarted-with-the-flag afterward; combined with ADR-0013
  (`ignore_changes = [user_data]`), an existing CP keeps running the
  bundled metrics-server until it is deliberately `-replace`d.
- **⚠️ Live-cluster remediation (one-time).** On a cluster that already
  has the bundled metrics-server running, after the flag is in place,
  delete the bundled resources so the chart's resources reconcile cleanly:

  ```bash
  kubectl -n kube-system delete deployment metrics-server
  kubectl -n kube-system delete service metrics-server
  # then let the ai-helm chart resync; and decommission any stale
  # old-generation `ai-metrics-server` ArgoCD app.
  ```

  Until that's done, the APIService can stay `Available=False` even with
  the flag set, because the bundled Deployment is still present and still
  mis-labelled.
- The three server blocks must stay in sync. If a future change adds a new
  server-install code path (e.g. another restore variant), it must also
  carry `--disable metrics-server` (and the other `--disable` flags). This
  duplication across blocks is an accepted cost of the role-conditional
  single-template design (arc42 § 5.3).
