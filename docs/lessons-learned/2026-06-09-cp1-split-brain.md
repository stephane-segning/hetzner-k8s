# 2026-06-09 — Control-plane split-brain: a rebuilt cp-1 founded its own cluster

## Summary

The bootstrap control plane `cp-1` was rebuilt while the cluster was still
running. Its cloud-init re-ran `k3s server --cluster-init` and founded a
**separate single-node etcd**. The Terraform-managed API LB
(`k8s.ssegning.com:6443`), which targets all control planes with a **TCP-only**
health check, then served the divergent cp-1 **alongside** the real cp-2/cp-3
cluster — a split-brain. Symptom: consecutive `kubectl get nodes` returned
different node sets and ~⅓ of API calls hit the wrong cluster. Resolved live by
stopping the divergent cp-1 and rejoining it to the real etcd. Prevented from
recurring by ADR-0017 (bootstrap join-not-init guard + HTTPS `/readyz` LB health
check), shipped in PR #23.

A second, process lesson: this happened because an **unattended scheduled task**
ran the recovery and did a db-wipe without the init→server flag swap. Don't
automate etcd/control-plane surgery.

## Symptom

Two back-to-back `kubectl get nodes` returned different clusters:

```
$ k get no
NAME                        STATUS   ROLES                AGE   VERSION
ssegning-hetzner-k3s-cp-1   Ready    control-plane,etcd   11m   v1.35.3+k3s1
$ k get no
NAME                            STATUS   ROLES                AGE
ssegning-hetzner-k3s-cp-2       Ready    control-plane,etcd   13d
ssegning-hetzner-k3s-cp-3       Ready    control-plane,etcd   13d
ssegning-hetzner-k3s-worker-1   Ready    <none>               7d18h
... (no cp-1)
```

`/readyz` through the LB was intermittently `ok` vs `apiserver not ready`
(~10/15 ok). `kubectl get nodes -o wide` external IPs were scrambled (CCM
mis-reporting after the reprovision churn — verify node identity with
`ssh root@<pub> hostname`, not `kubectl`).

## Root cause

cp-1 is the `--cluster-init` etcd founder. `bootstrap/cloud-init/node.yaml` ran
`--cluster-init` unconditionally for `initialize_cluster = true`. When cp-1 was
rebuilt with a fresh/empty etcd, it founded a NEW single-node cluster
(`cluster-id` distinct from the real one) instead of rejoining cp-2/cp-3.

The API LB made it visible: it targets all CPs (correct — ADR-0014) but
health-checks **TCP `:6443`** only. A TCP-open port doesn't distinguish a
divergent (or crash-looping) apiserver from a real one, so the LB round-robined
across both clusters.

At inspection, cp-1's k3s was actually crash-looping (`912` restarts) on:

```
tombstone file has been detected but --server is empty: backup and delete
${datadir}/server/db to create a new cluster, or set --server to rejoin
```

i.e. it had been removed from etcd (tombstone) but its config still said
`--cluster-init` with no `--server` target — so it could neither rejoin nor
stay out. A prior recovery attempt had wiped the db (clearing the tombstone),
letting it finally come up as its own cluster → the split-brain.

## Fix (live)

1. **Stop the split-brain.** On the divergent node, confirm it sees only itself
   then stop + disable k3s (ejects it from the LB within one health-check
   interval):

   ```sh
   ssh -J root@<cp-pub> root@10.0.0.10 \
     'k3s kubectl get nodes --no-headers | wc -l'   # 1 == divergent
   ssh -J root@<cp-pub> root@10.0.0.10 'systemctl stop k3s && systemctl disable k3s'
   ```

   API immediately went consistent (8/8 identical `get nodes`, `/readyz` 15/15).

2. **Rejoin cp-1 to the real cluster.** Park the divergent db, swap
   `--cluster-init` → `--server`, **verify the swap before starting**, then
   start:

   ```sh
   mv /var/lib/rancher/k3s/server/db /var/lib/rancher/k3s/server/db.splitbrain-bak-$(date +%s)
   #   edit /etc/systemd/system/k3s.service:  --cluster-init  →  --server https://10.0.0.11:6443
   grep -c -- '--cluster-init' /etc/systemd/system/k3s.service   # MUST be 0 before start
   systemctl daemon-reload && systemctl enable --now k3s
   ```

   cp-1 joined as an etcd **learner → promoted** member (`cluster-id` matched the
   real cluster); quorum back to 3.

> ⚠️ The db-wipe **without** the flag swap is exactly what creates the
> split-brain. Both steps are mandatory, in order, with the `grep -c` check
> gating the start. Full runbook: `docs/recovery.md → Control-Plane Split-Brain`.

## Prevention (ADR-0017, PR #23)

- **Bootstrap guard** — the cluster-init node probes its peer CPs
  (`control_plane_peer_ips` from `locals.tf`) and JOINs an existing cluster
  instead of re-running `--cluster-init`. A rebuilt cp-1 can no longer found a
  divergent cluster.
- **API LB `/readyz` health check** — HTTPS `/readyz` (accepting `401`, since
  k3s `/readyz` is auth-gated) replaces the TCP-only check, so the LB stops
  routing to a not-serving apiserver.

## Rollout — what's left to do

PR #23 is merged to `main`, but **merge ≠ apply**. To fully roll out:

- [ ] **Apply the LB health-check change** — `terraform apply` (or the **Infra
      Up** GitHub Actions workflow). It's an **in-place** `hcloud_load_balancer_service`
      update (no node replacement). Per ADR-0013 (`ignore_changes = [user_data]`)
      the same apply will **not** touch nodes for the cloud-init change.
  - **Precondition (verified 2026-06-09):** every CP returns `HTTP 401` to
    `curl -ksi https://<cp>:6443/readyz` — accepted by
    `status_codes = ["2??","401"]`. If any returns `5xx`, do **not** apply (the
    LB would eject all CPs); revisit the status-code list first.
  - **Validate at apply:** keep `watch kubectl get nodes` running; after the
    apply, confirm the LB still shows all CPs healthy (consistent `get nodes`,
    `/readyz` stays `ok`). Rollback = revert the `health_check_*` fields to
    `protocol = "tcp"` and re-apply.
- [ ] **Bootstrap guard** — no apply needed; it takes effect on the **next CP
      `-replace`/reprovision**. The next time you replace cp-1, confirm its
      cloud-init log shows `Existing cluster detected … JOINING instead of
      --cluster-init`, and that it joins (its local `get nodes` shows all nodes).
- [ ] **Cleanup** — once confident, remove the parked divergent db on cp-1
      (`/var/lib/rancher/k3s/server/db.splitbrain-bak-*`).

## Lessons

- **Never run etcd/control-plane surgery from an unattended/scheduled agent.**
  A scheduled "supervised" task fired and ran the destructive db-wipe without
  the init→server flag swap — that's what produced the split-brain. Destructive
  CP work is done live, step by step, verifying before each `systemctl start`.
- **`--cluster-init` is a once-ever flag.** Any path that can re-run it on an
  existing cluster is a latent split-brain. Guard it with a "cluster already
  up?" probe (ADR-0017).
- **A TCP health check on an apiserver LB is not enough** — it can't tell a
  divergent/not-serving apiserver from a real one. Probe `/readyz`.
- **Trust SSH `hostname`, not `kubectl -o wide` IPs**, when the CCM has been
  churned — external IPs were scrambled here. The laptop has no route to the
  `10.0.0.0/24` private net; reach nodes via `ssh -J <public-cp> root@10.0.0.x`.
</content>
