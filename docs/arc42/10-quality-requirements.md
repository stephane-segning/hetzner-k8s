# 10. Quality Requirements

Concrete quality scenarios. Each is a "given / when / then" with a
measurable target, not just an adjective.

## 10.1 Recoverability

**Q1: Restore from S3 with no manual intervention**

Given a cluster whose control planes are all destroyed and whose etcd
snapshots are intact in S3, when the operator triggers `Infra Up` with
`restore_from_s3=true` and a valid snapshot filename, then:

- the workflow completes successfully within 15 minutes (the `/livez`
  gate budget for restore mode), without any operator action on the nodes
  themselves;
- `kubectl get nodes` shows all expected nodes Ready within 5 minutes
  after the workflow ends;
- the restored cluster contains every Kubernetes object that was in the
  snapshot at the snapshot's timestamp.

Measured indirectly via:

- `Verify Etcd Backups` workflow (snapshot recency)
- Manual `kubectl get pods -A | grep -vc Running` after Platform Up
- Argo CD home cluster sync status

**Q2: Re-running restore is safe**

Given a cluster that is already restored and healthy, when the operator
triggers `Infra Up` again with `restore_from_s3=true`, then the workflow
must:

- detect the API is reachable (HTTP 200/401/403 to `/livez`);
- skip the cluster-reset on cp-1 (sentinel present);
- only re-provision workers (per ADR-0006);
- complete without etcd quorum loss.

## 10.2 Reliability

**Q3: Routine Infra Up is idempotent**

Given an unchanged repo and a healthy cluster, when the operator triggers
`Infra Up` (no restore), then the Terraform plan shows zero changes and
the workflow finishes green in under 5 minutes.

**Q4: Etcd snapshot cron survives partial outage**

Given any one of the three CPs being down, when the next
`etcd-snapshot-schedule-cron` tick fires, then at least one S3 snapshot
is produced.

## 10.3 Observability

**Q5: Failed Infra Up is loud**

Given Infra Up fails (cloud-init error, k3s crash-loop, network race),
when the workflow finishes, then it must:

- exit non-zero;
- write the suspected failure cause to `GITHUB_STEP_SUMMARY`;
- never report green if the API is unreachable through the LB.

This is the contract the `/livez` gate enforces.

**Q6: Backup health is queryable**

`Verify Etcd Backups` workflow must report whether a snapshot newer than
a configurable threshold (default 24h) exists in S3.

## 10.4 Security

**Q7: No long-lived plaintext credentials on node disk**

Given the restore branch downloads a snapshot using `mc` with S3
credentials, when restore completes (success OR failure), then:

- `/root/.mc/` MUST NOT exist (we use `mktemp -d` + `trap '...' EXIT`);
- the cloud-init script that embeds creds is `0700`;
- no future process re-reads the creds from disk.

**Q8: Direct public ingress to nodes stays disabled**

Given the firewall is Terraform-managed, when Infra Up applies, then no
rule opens public 80, 443, 6443, or 2379-2380 to node IPs. Routine
verification: read `terraform/modules/firewall/main.tf`.

## 10.5 Cost

**Q9: Monthly cloud-project cost stays under €200 net**

Re-baselined 2026-07-25 (was "under €110"). The original target predated
four independent changes, none of which were cost regressions to fix:

1. Hetzner raised prices ~25% on 2026-04-01 (CPX22 €5.99 → €7.99).
2. Workers scaled 2 → 4 × CPX42 (€102/mo — the largest single line).
3. A third LB (`core-gateway`) joined `api` + `traefik-ingress`.
4. Control planes resized CPX22 → CPX32 (**ADR-0018**).

Given the current topology (3 × CPX32 + 4 × CPX42 + 3 × LB11 + Object
Storage + ~25 CSI volumes), steady-state is **~€185-190/mo net** (~€220
gross incl. 19% VAT), per `Makefile show-costs`. Measured at the end of
each Hetzner billing period.

**Scope:** this budget covers the *Cloud project* only. The off-cloud Robot
GPU servers bill separately and dominate total spend — judge them against
their own budget, not this one.
