# Roadmap

Forward-looking plan for the `ssegning-hetzner-k3s` cluster, written
immediately after the May 2026 restore arc. The intent is to keep the
follow-up work visible (so it doesn't quietly bitrot) and to mark
deliberate non-decisions (so a future reader knows we considered them).

Companion documents:

- [`DECISIONS.md`](../DECISIONS.md) — macro design choices already made
- [`docs/arc42/11-risks-and-technical-debt.md`](arc42/11-risks-and-technical-debt.md) — risk and debt register
- [`docs/lessons-learned/2026-05-cluster-restore.md`](lessons-learned/2026-05-cluster-restore.md) — narrative behind
  most of the "Next" items

## How to read

Items are grouped by **horizon** (Now → Next → Later → Wishlist) and
tagged with a priority:

- **P0** — blocker on something operational; do before next planned change
- **P1** — non-blocking but real; do within the horizon
- **P2** — quality-of-life; do when the horizon's P1s are done
- **P3** — exploratory / aspirational

Each item references the risk (R-N), debt (D-N), or ADR it relates to in
the rest of the docs. Items are deliberately small — anything bigger gets
its own ADR.

---

## Now — immediate post-restore hygiene

The cluster came back. These are the things to close out in the same
work session so we leave the system in a known-good state.

### N-1 — Run **Verify Etcd Backups** workflow once

**P0.** Confirms that the restored snapshot is registered as an
`etcdsnapshotfile` and that the next scheduled cron tick will produce a
fresh snapshot in S3.

The just-restored snapshot itself counts toward "snapshot newer than
24h". After the next 6-hour cron tick (`etcd_snapshot_schedule_cron`)
produces a new snapshot on the restored cluster, the verification has
real recency to check.

### N-2 — Wait for non-Running pods to bind their PVCs

**P0 (operational).** Hetzner CSI does a noisy first-reconcile pass after
restore: stale `VolumeAttachment` objects (pointing at destroyed VM
names) fail to detach, get garbage-collected, and the controller creates
new attachments for the right nodes. Self-healing in ~5-10 min.

Expected residue post-restore (in the May 2026 run):
`keycloak-ha-app-0`, `keycloak-ha-cluster-2`, `mail-0`, `redis-ha-*`,
`traefik-*` waiting on PVC bind.

`kubectl describe pod <name>` surfaces whether a Pod is blocked on
`FailedAttachVolume` (transient) or something else.

### N-3 — Rotate `ETCD_S3_*` GitHub Action secrets

**P1.** During restore, S3 credentials are templated into cloud-init
`user_data`. They share the trust boundary of `HCLOUD_TOKEN` (also in
`user_data`), but the exposure window is real. Rotation closes it.

Procedure:

1. Hetzner Cloud Console → Object Storage → Credentials → create new
   access key pair.
2. Update GH Actions secrets `ETCD_S3_ACCESS_KEY_ID`,
   `ETCD_S3_SECRET_ACCESS_KEY`.
3. Trigger **Platform Up** to re-apply the
   `k3s-etcd-snapshot-s3-config` Secret in `kube-system` with the new
   creds.
4. Revoke the old access key.

References: ADR-0009, R-7.

### N-4 — Trigger Argo CD reconcile against the restored cluster

**P1.** Argo CD in the home cluster sees the restored cluster come back
through the same `argocd-manager` ServiceAccount token (it survived in
the etcd snapshot). Reconcile picks up any drift between the restored
manifests and Git head.

If the home Argo CD is also Argo-CD-of-itself, watch for it to
self-sync. If not, manually trigger a hard refresh of the
`ssegning-hetzner-k3s` cluster registration.

### N-5 — Migrate existing nodes to the Terraform-held node password (optional)

**P2.** ADR-0012 has Terraform hold a stable per-node password and
cloud-init write it at first boot. Nodes provisioned **before** that
change keep their original random on-disk password and a matching
`<nodename>.node-password.k3s` Secret — the two are mutually consistent,
so those nodes stay healthy through reboots and need **no** action. They
adopt the Terraform-held password automatically the next time they are
`-replace`d (the deliberate, recovery-grade path; with ADR-0013 a plain
edit never replaces them).

So no migration is *required*. There are two ways to converge sooner if
desired:

1. **Lazy (recommended): do nothing.** Let each node adopt the new
   password on its next deliberate `-replace`. Until then it runs happily
   on its current consistent on-disk/Secret pair.
2. **Eager:** for a specific node, write its Terraform-held password to
   disk and re-register, in one shot, e.g.:
   ```bash
   # value from: terraform output (add an output) or state; node-side:
   printf '%s\n' "<node_password from TF state for this node>" \
     > /etc/rancher/node/password && chmod 0600 /etc/rancher/node/password
   # then on a control plane, clear the stale Secret so it is recreated:
   kubectl -n kube-system delete secret "ssegning-hetzner-k3s-<node>.node-password.k3s"
   systemctl restart k3s   # or k3s-agent on a worker
   ```
   Only worth it if you want determinism before the node is otherwise
   replaced. References: ADR-0012, ADR-0013, D-4 (closed).

> **Do NOT** just delete the Secret on a running pre-ADR-0012 node and
> stop there: the running node immediately recreates the Secret from its
> *current old random* on-disk password, so a later `-replace` (fresh
> disk → Terraform password) would still mismatch. The eager path above
> writes the disk password first; the lazy path avoids the issue entirely
> because `-replace` starts from the Terraform password and a Secret that
> was either cleared or never existed for that fresh identity.

> **Note.** The 2026-06-02 incident (all three workers NotReady after a
> reboot) was this failure family, remediated live by deleting the worker
> Secrets (which was correct *there* because the goal was to re-pin the
> nodes' then-current on-disk passwords). ADR-0012 prevents recurrence.

---

## Next — next 1-3 months

Real follow-ups from the cluster-restore arc that we deferred
deliberately because they aren't blocking.

### X-1 — Add `render-with-vars` + yamllint to `make test`

**P1.** Closes **D-1**. The May 2026 cluster-restore arc burned two PRs
on bash-heredoc-vs-YAML-literal-block indentation traps in cloud-init.
We have static YAML structure validation in `tests/render/` but no step
that renders the template with realistic variable values and parses the
result.

Concrete:

1. Add `tests/render/cloud-init.sh` that uses `terraform console` (or a
   minimal `terraform apply` against a scratch module) to render the
   cloud-init template with synthetic values that *exercise* the
   `restore_from_s3` branch.
2. Pipe the rendered YAML through `yq e .` or `python3 -c 'import yaml; yaml.safe_load(...)'`.
3. Wire into `make test-render`.

This would have caught PR #5's failure before we ever pushed it to
Hetzner.

### X-2 — Hetzner Object Storage bucket versioning + lifecycle on etcd snapshots

**P1.** Closes **D-7** and partially closes **R-2**. Today the etcd
snapshots live in a Hetzner Object Storage bucket with default settings.
A bucket deletion (accidental or malicious) loses all snapshots.

Concrete:

1. Enable bucket versioning on the etcd snapshots bucket.
2. Add a lifecycle rule: delete non-current versions after 30 days.
3. Document the rotation cycle in `docs/runbooks/` (if/when we add a
   runbooks directory).

This is a Hetzner Console action; no code change required.

### X-3 — Track the upstream k3s `decompressSnapshot` bug

**P1.** Closes **D-2**. We carry workarounds for k3s 1.35.x in
`bootstrap/cloud-init/node.yaml` (pre-decompression, `--etcd-s3=false`,
`--node-ip` repetition). All three are documented (ADRs 0003, 0010, 0011)
but maintaining them as the codebase evolves is real work.

Concrete:

1. File a k3s GitHub issue describing the
   `filepath.Join(snapshotDir, absRestorePath)` doubling, with the
   reproduction and the suggested patch (`if filepath.IsAbs(snapshotFilename) { snapshotPath = snapshotFilename }`).
2. Link the issue here and in ADR-0003.
3. When fixed upstream and we upgrade past the fixed version, write a
   new ADR superseding 0003 and remove the pre-decompress step. Keep
   the rest (idempotency sentinel, SKIP_ENABLE, `--node-ip`) — those
   are not bug-driven.

### X-4 — Make the "post-recovery flip restore_from_s3=false" pattern obvious

**P2.** Closes **D-9**. Today the operator-facing instruction is buried
in `docs/recovery.md` step 8. Although the API-reachability gate
(ADR-0007) makes re-runs *safe*, leaving `restore_from_s3=true` as a
default in the operator's mental model is friction.

Concrete:

1. In `docs/recovery.md`, move the "flip back to false" guidance to a
   bold block at the end of the procedure section.
2. Consider opening the post-recovery follow-up PR ourselves as part of
   the Infra Up workflow output — a step that prints "Next: open a PR
   that sets `restore_from_s3` back to `false`" in `GITHUB_STEP_SUMMARY`.

### X-5 — Pre-flight S3 snapshot listing in the workflow

**P2.** When triggering Infra Up in restore mode, the operator must
type the exact snapshot filename. A typo is rejected by cloud-init but
only after the VMs are created, which wastes ~3 minutes per typo.

Concrete:

1. In the Infra Up `Validate restore inputs` step, when
   `restore_from_s3=true`, also run `mc ls` against the configured S3
   path to confirm the named file exists.
2. Fail fast with the list of available snapshots in
   `GITHUB_STEP_SUMMARY`.

### X-6 — Inventory `make` targets vs. the "GH Actions is the only supported control surface" rule

**P2.** Closes **D-6**. `make apply`, `make destroy`, `make bootstrap`,
`make platform-install` exist. AGENTS.md says they're break-glass. They
likely bitrot — they don't have a regular signal.

Choices: (a) delete them, (b) fold their checks into a workflow, (c)
add a periodic validation that they at least pass `make test`.

Recommendation: keep `make plan/apply/destroy` (they're useful local
sanity); delete `make bootstrap` (the cloud-init flow replaces it);
keep `make platform-install` only as long as Platform Up's
`./bootstrap/scripts/install-platform.sh` is shared.

---

## Later — 3 to 12 months

Larger pieces of work; each likely deserves its own ADR before
implementation.

### L-1 — Cross-region etcd snapshot replication

**P2.** Closes **R-1** and **R-2**. Today the etcd snapshot bucket lives
in the same Hetzner Cloud project (and likely the same region) as the
cluster. A regional Hetzner incident takes both down.

Approaches considered:

- Hetzner Object Storage cross-region: not currently a Hetzner feature.
- Use a separate Hetzner project in a different region: doubles the
  storage cost (~€6/month) but adds real isolation.
- Replicate to a non-Hetzner store (Backblaze B2, Wasabi, S3 itself):
  same model, different provider.

Decision driver: how much off-Hetzner blast radius do we want? If we're
trying to defend against "Hetzner billing issue" not just "Hetzner
regional outage", off-Hetzner is required.

### L-2 — Cross-region home Argo CD

**P3.** Closes **R-9**. If both this cluster and the home cluster are
in `nbg1`, a regional incident takes both down. Less acute than L-1
because Argo CD is reconciling-only; a brief Argo CD outage doesn't
take workloads down.

### L-3 — Mirror `mc` to our own infrastructure

**P3.** Closes **R-8**. Today restore requires `dl.min.io` reachable.
If MinIO's CDN goes down at the exact moment of restore, the operator
is stuck. Frequency: very low.

Mitigation: copy the `mc` binary to our own Hetzner Object Storage
bucket, change the cloud-init download URL.

Cost: ~25 MB of bucket storage; ~5 lines of cloud-init change.

### L-4 — Replace `--cluster-reset-restore-path` with direct `etcdutl` restore

**P3.** Closes the entire class of k3s-cluster-reset bugs (ADR-0003,
ADR-0010, ADR-0011). Instead of asking k3s to do the restore, use
`etcdutl snapshot restore` directly to populate the etcd data dir, then
start k3s normally.

Trade-off: we take ownership of the etcd member-name / cluster-token /
peer-URLs config that k3s manages today. The blast radius for getting
that wrong is high (corrupted etcd).

Recommendation: don't do this until we hit a third k3s restore bug.

### L-5 — Live integration test of Infra Up

**P3.** Closes **D-5**. Today our `make test` is static: terraform
fmt + validate, YAML render, shellcheck. No end-to-end test of a real
Infra Up run.

A live test would:

1. Provision an ephemeral test cluster (`hetzner-k3s-test`,
   `CPX11` × 1 cp + 1 worker) on every PR to `bootstrap/cloud-init/`
   or `.github/workflows/infra-up.yml`.
2. Wait for `/livez`.
3. Tear down.

Cost: each run is ~€0.05 (Hetzner per-hour billing on the smallest
servers); ~20 min wall-clock. Feasible but adds workflow complexity.

### L-6 — Workflow that detects stale `restore_from_s3=true` defaults

**P3.** If a future operator forgets to flip `restore_from_s3` back to
`false` (cf. X-4) and the workflow defaults move accidentally, the
sentinel + reachability gate already protect against the destructive
case. But it's worth a CI check that `restore_from_s3` defaults to
`false` in the workflow_dispatch input definition.

---

## Wishlist — aspirational, may never happen

Ideas worth recording so they don't get re-proposed; not commitments.

### W-1 — External-Secrets-managed Hetzner / S3 creds

Today `HCLOUD_TOKEN` and `ETCD_S3_*` live in GH Actions secrets and
land in cloud-init `user_data`. An external-secrets-style flow could
fetch them at restore time from a separate secret store (Vault,
1Password Connect, etc.) using a short-lived signed URL embedded in
the workflow. Removes inline-cred exposure.

Cost: another service to operate; another dependency in the recovery
path (which is the worst place to add one).

### W-2 — Multi-cluster support

Today the Terraform composition is hard-coded to one environment in
`terraform/envs/prod/`. Splitting into a reusable module + per-cluster
composition would let the same repo manage multiple Hetzner clusters
(staging, dev, …).

Not on the table while the cluster is one-of-one.

### W-3 — Move to Talos or k0s

If k3s' restore-path quirks become a recurring source of incidents,
switching distributions is worth considering. Talos has a more
opinionated, immutable model and a cleaner snapshot/restore story. k0s
is a closer drop-in.

Cost: rewriting cloud-init, recovery procedure, all ADRs. Bar should be
high.

### W-4 — A self-deploy of this repo

For sufficiently meta operators: a Hetzner cluster that bootstraps from
nothing but the contents of this repo + `HCLOUD_TOKEN`. Today there are
a few external dependencies (Hetzner Object Storage bucket for Terraform
state, GH Actions runners). A truly "cold-start" version would
provision its own state backend on first run.

Probably not worth doing; the existing assumptions are reasonable.

---

## Conventions for keeping this document healthy

- **One item per concrete piece of work.** If something feels too big
  to summarize in three sentences, split it.
- **Tag with priority and horizon.** Items move from Wishlist → Later →
  Next → Now → done.
- **Cite the ADR / risk / debt ID** so the reader can find the context.
- **When an item is done, remove it** (not strike-through). The
  long-form record lives in commit history and in any ADR the work
  produced.
- **When an item is deliberately not-doing, mark it as a decision** in
  `DECISIONS.md` or in a "Decisions deferred" section so the
  next reader doesn't re-propose it.
- **Don't let this become a list of every micro-thought.** The
  threshold is "would a future operator regret not knowing this was
  considered?" If no, it doesn't go here.
