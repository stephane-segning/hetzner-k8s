# ADR-0017: Guard against control-plane split-brain (bootstrap join-not-init + `/readyz` LB health check)

## Status

Accepted

## Context

The bootstrap control plane (`control-plane-01`, private `10.0.0.10`) is the
`--cluster-init` etcd founder. Its cloud-init **unconditionally** runs
`k3s server --cluster-init` (`bootstrap/cloud-init/node.yaml`, the
`initialize_cluster` / non-restore branch). Non-bootstrap CPs and workers wait
on the bootstrap node and `--server`-join it.

That `--cluster-init` is only correct **once**, on a genuinely fresh cluster. If
the bootstrap node is ever rebuilt while the cluster still exists (e.g. a
`terraform -replace` of `control-plane-01`, or a manual db-wipe), it re-runs
`--cluster-init` and founds a **brand-new single-node etcd** — divergent from
the surviving `cp-2`/`cp-3` cluster.

This bit us in prod (2026-06-09, see
`docs/lessons-learned/2026-06-09-cp1-split-brain.md`). The recreated cp-1 formed
its own cluster, and because the **Terraform-managed API LB** (`*-api`, the
`k8s.ssegning.com:6443` endpoint) targets **all** control planes with a
**TCP-only** health check, it served the divergent cp-1 **alongside** the real
cluster:

- Consecutive `kubectl get nodes` returned **different node sets** (split-brain).
- ~⅓ of API calls hit the wrong apiserver ("apiserver not ready" / wrong state).
- A TCP health check can't tell the difference — port `6443` is open on the
  divergent (and even on a crash-looping) apiserver, so the LB kept routing to it.

Two gaps allowed this: (1) the bootstrap node has no "is the cluster already
up?" check before `--cluster-init`, and (2) the API LB's health check only
proves the TCP port is open, not that the apiserver is actually serving.

## Decision

**1. Bootstrap split-brain guard (`bootstrap/cloud-init/node.yaml`, `terraform/envs/prod/locals.tf`).**
Before `--cluster-init`, the bootstrap node probes its **peer control-planes**
and JOINs an existing cluster instead of re-initializing:

```sh
K3S_CLUSTER_FLAG="--cluster-init"
if [ -n "${control_plane_peer_ips}" ]; then
    for PEER_CP in ${control_plane_peer_ips}; do
        if curl -sk --max-time 5 "https://$PEER_CP:6443/healthz" >/dev/null 2>&1; then
            K3S_CLUSTER_FLAG="--server https://$PEER_CP:6443"   # JOIN, not init
            break
        fi
    done
fi
# ... k3s server ... $K3S_CLUSTER_FLAG ...
```

`control_plane_peer_ips` is rendered per-node in `locals.tf` (the CP private
IPs, **excluding self**; workers get `""`). `--cluster-init` now runs **only**
when no peer answers — a genuinely fresh cluster. The empty-list case
(`control_plane_count = 1`) is guarded so the loop never becomes
`for PEER_CP in ; do` (a bash syntax error). The **restore-from-S3** branch is
unchanged: that's an explicit operator action (ADR-0002/0004) and must still
cluster-reset.

**2. API LB health check: HTTPS `/readyz`, not TCP (`terraform/modules/loadbalancer`, `terraform/envs/prod/main.tf`).**
The `*-api` LB now health-checks `GET /readyz` over TLS instead of a bare TCP
connect, so it only routes to an apiserver whose HTTP layer is actually serving.
The loadbalancer module gains `health_check_tls` and `health_check_status_codes`
(both non-breaking; defaults preserve prior behavior and `tcp` checks ignore the
`http` block). The k3s apiserver requires auth even for `/readyz`, so an
unauthenticated probe returns **401 when UP** (and nothing when down) — `401` is
therefore accepted as healthy alongside `2xx`:

```hcl
health_check_protocol     = "http"   # Hetzner: http + tls = true ⇒ HTTPS probe
health_check_tls          = true
health_check_path         = "/readyz"
health_check_status_codes = ["2??", "401"]
```

## Consequences

- A rebuilt bootstrap CP can no longer found a divergent cluster — it joins the
  surviving etcd. This closes the split-brain failure mode at its source.
- The API LB stops serving a crash-looping or otherwise-not-serving apiserver
  (TCP-open but not answering HTTP). It does **not** by itself detect a
  *divergent-but-healthy* apiserver (that returns 401 like any healthy one) —
  the bootstrap guard is what prevents the divergent node from existing; the
  `/readyz` check is defense-in-depth for the not-serving case.
- **Rollout is not automatic.** The cloud-init guard only takes effect on the
  next CP **(re)provision** (`-replace`), per ADR-0013 (`ignore_changes =
  [user_data]`). The LB change needs a **`terraform apply`** (or the Infra Up
  workflow) — it's an in-place `hcloud_load_balancer_service` update, no node
  replacement. See the rollout checklist in the lessons-learned post-mortem.
- **Apply-time trap (LB):** if `/readyz` ever returns `5xx` (not `401`) on a
  healthy CP, the `status_codes` list would mark every CP unhealthy and the LB
  would eject all backends → API outage. Validate before/at apply:
  `curl -ksi https://<cp>:6443/readyz` must return `401` on each CP (verified
  2026-06-09). If k3s's `/readyz` auth behavior changes, revisit the status-code
  list.
- **Operational lesson (recorded separately):** never run this kind of
  etcd/control-plane surgery from an unattended/scheduled agent — a scheduled
  "supervised" task fired and did a db-wipe **without** the init→server flag
  swap, which is what produced the split-brain. Destructive CP work is
  live-supervised, step by step.

## Related

- Incident + recovery runbook: `docs/lessons-learned/2026-06-09-cp1-split-brain.md`,
  `docs/recovery.md → Control-Plane Split-Brain`.
- Builds on / relates to: ADR-0007 (gate CP `-replace` on API reachability),
  ADR-0013 (`ignore_changes = [user_data]`), ADR-0014 (API LB targets the CPs by
  design), ADR-0002/0004 (the restore path the guard deliberately leaves alone).
- Implemented in PR #23.
</content>
