# ADR-0008: Self-validate Infra Up via `/livez` gate

## Status

Accepted

## Context

In the early restore iterations, Infra Up returned green as soon as
`terraform apply` finished. Cloud-init had not yet run on the new VMs;
the cluster API was not yet reachable. The operator would then trigger
Platform Up, which failed at `kubectl version --request-timeout=10s`
with "the server is currently unable to handle the request" — leaving
the operator to diagnose whether the cluster was still booting, had
silently failed mid-restore, or had a deeper problem.

A successful Infra Up should *mean* a reachable cluster, end-to-end.
Otherwise green-on-the-workflow is meaningless and the operator has to
do their own polling.

## Decision

Add a `Wait for Kubernetes API to become ready` step to Infra Up, after
`Ensure servers are powered on` and before `Show endpoint summary`. The
step polls `<api_server_endpoint>/livez` on a fixed interval and treats
**200**, **401**, or **403** as "API is up" (TLS handshake works,
apiserver is serving; the auth response is not what we care about). It
fails the workflow on timeout with a triage hint in
`GITHUB_STEP_SUMMARY`:

```bash
DEADLINE=$(( $(date +%s) + 600 ))     # 10 min routine
[ "$RESTORE_FROM_S3" = "true" ] && DEADLINE=$(( $(date +%s) + 900 ))  # 15 min restore

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    status=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
        "$API_ENDPOINT/livez" 2>/dev/null || echo "000")
    case "$status" in
        200|401|403) echo "API ready: HTTP $status"; exit 0 ;;
    esac
    sleep 10
done

{
    echo "Kubernetes API did not become ready in time."
    echo "Likely causes:"
    echo "  - cloud-init failed on the bootstrap control plane"
    echo "  - private NIC did not come up (k3s cannot bind --node-ip)"
    echo "  - S3 snapshot restore failed"
} | tee -a "$GITHUB_STEP_SUMMARY"
exit 1
```

Restore runs get a longer deadline (15 min) because `package_upgrade`
plus k3s install plus snapshot download plus `--cluster-reset` legitimately
takes longer than a routine boot. The triage hint points the operator at
the three failure modes most likely to be at play.

## Consequences

- A green Infra Up means the cluster is genuinely up and serving the API
  via the LB. Platform Up can run immediately after with no extra wait.
- Silent post-apply failures (cloud-init failing, k3s.service crash-looping,
  empty cluster auto-rescue from ADR-0004 before we fixed it, etc.) now
  surface as a failed step with a useful summary instead of as a green
  workflow + broken cluster.
- Worst-case wall-clock for Infra Up shifts from "~3 min apply, you hope
  the cluster is up" to "~5-12 min total including readiness wait". Net
  win because the operator stops re-checking manually.
- The gate uses the API LB as the canonical signal. It accidentally also
  catches: API LB target health check failing, all CP backends dead,
  certificate-signing CA mismatch (TLS handshake errors register as 000).
