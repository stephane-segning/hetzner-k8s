# ADR-0007: Gate non-bootstrap CP `-replace` on API reachability

## Status

Accepted

## Context

The first version of the restore workflow (PR #6) added an unconditional
`-replace=module.servers.hcloud_server.main["control-plane-NN"]` for every
non-bootstrap CP whenever `restore_from_s3=true`. The reasoning was sound
for the **first** restore: the previous-era cp-2 and cp-3 had stale etcd
data from a different cluster, and joining a learner with an existing data
dir would conflict — so they had to be fresh VMs.

PR #13 then extended the same `-replace` pattern to workers (ADR-0006).
At that point an operator triggering Infra Up a *second* time in restore
mode (for example to apply the worker replacement after a first run that
left cp-1 healthy but workers misaligned) hit:

```
"Failed to test etcd connection: this server is not a member of the etcd cluster"
"transport: authentication handshake failed: context deadline exceeded"
"dial tcp 10.0.0.11:2380: connect: connection refused"   ← old cp-2, destroyed
"dial tcp 10.0.0.12:2380: connect: connection refused"   ← old cp-3, destroyed
```

The sentinel on cp-1 (ADR-0004) correctly skipped the cluster-reset, so
cp-1 retained its restored etcd. But Terraform parallel-destroyed cp-2
and cp-3, leaving cp-1 as the sole surviving etcd voter. Etcd needs
majority of the **original** voter set to remain healthy (it does not
auto-remove unreachable members), so 1 of 3 voters means **no quorum**.
The new cp-2 and cp-3 came up and tried to join, but adding a member is
itself a write that requires quorum, so they couldn't.

Recovery from that state required ssh'ing to cp-1 and running
`k3s server --cluster-reset` (without `--cluster-reset-restore-path`) to
forget the dead members — exactly the kind of manual intervention the
GH-Actions-only operating model is supposed to prevent.

## Decision

Probe the API load balancer for `/livez` before computing the
`-replace` flags. Use the response to decide whether to force-replace
non-bootstrap CPs:

```bash
api_status=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
  "$API_ENDPOINT/livez" 2>/dev/null || echo "000")
case "$api_status" in 200|401|403) cluster_reachable=true ;; esac

if [ "$cluster_reachable" = "true" ]; then
    # Already-restored cluster: only -replace workers.
    # cp-2 and cp-3 stay; etcd quorum preserved.
else
    # First restore: -replace non-bootstrap CPs and workers.
fi
```

200, 401, and 403 are all treated as "TLS handshake works, apiserver is
serving" — the apiserver may legitimately refuse our unauthenticated
request, but the cluster is up and we should not churn the CPs.

Workers (ADR-0006) are always force-replaced when `restore_from_s3=true`
regardless of API reachability, because their TLS pinning hazard is
orthogonal to etcd quorum.

## Consequences

- A re-run of restore mode against an already-healthy cluster is now a
  no-op for the control planes. The etcd quorum-break trap is closed.
- The gate uses the API LB as its proxy for "cluster is healthy". An
  operator can intentionally force a full CP rebuild by stopping all CP
  servers (or destroying them out-of-band) before triggering Infra Up;
  the LB then returns connection-refused/000 and the workflow falls
  back to the first-restore behavior. This is the intended escape
  hatch.
- The probe is best-effort (`--max-time 5`). If the LB is briefly
  flapping during a run, we could misclassify and over-aggressively
  replace CPs. Acceptable: the surrounding 5-minute Infra Up + 15-minute
  `/livez` gate make a brief flap unlikely, and a misclassification
  toward "first restore" replaces extra nodes but is still correct
  behavior.
- The decision is co-located in `.github/workflows/infra-up.yml` rather
  than in Terraform; Terraform can't easily ask "is this cluster
  reachable" as part of a plan. The workflow is the natural place.
