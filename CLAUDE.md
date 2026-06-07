# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Operating model (read first)

This repository operates a production-ish Hetzner k3s cluster. **GitHub Actions is the only supported control surface.** `make apply`, `make destroy`, `make bootstrap`, and `make platform-install` exist for **break-glass** only — they are not the day-to-day path and shouldn't be the path you propose unless explicitly asked.

The five supported workflows live in `.github/workflows/`:

| Workflow                 | Purpose                                                                                          |
|--------------------------|--------------------------------------------------------------------------------------------------|
| `infra-up.yml`           | Provision/refresh infra; optionally restore etcd from S3 or force-replace specific nodes (`replace_nodes`). Self-validates (API `/livez` + all expected nodes Ready) before reporting success. |
| `infra-down.yml`         | Power off servers (preserves disks + Terraform state)                                            |
| `infra-destroy.yml`      | `terraform destroy` (guarded)                                                                    |
| `platform-up.yml`        | Install/upgrade Cilium, Hetzner CCM/CSI, Traefik, base manifests, etcd-S3 Secret                |
| `verify-etcd-backups.yml`| Confirm recent S3 etcd snapshots exist                                                           |

To recover a single dead/wedged node (the routine, no-SSH way), run Infra Up with `replace_nodes=<key>` (e.g. `worker-3` or `worker-03`; comma/space-separated for several). It force-replaces only those VMs so cloud-init re-runs and they rejoin fresh; control-plane keys additionally require `allow_control_plane_replacement=true`. See `docs/recovery.md`.

Constraints recorded in `AGENTS.md` that must shape any change:

- Do **not** commit `terraform.tfvars` or generated backups.
- Terraform state lives in Hetzner Object Storage via the S3 backend; assume remote state for any workflow change.
- Terraform owns: network, subnets, firewalls, servers, worker data volumes, the API LB on `:6443`. Kubernetes + Hetzner CCM owns ingress LBs from `Service.type=LoadBalancer`. Don't mix these.
- Argo CD lives in a **separate home cluster** and manages long-lived workloads in this one via GitOps. We don't run Argo CD here.
- Keep Cilium as the CNI, swap disabled, k3s `local-storage` disabled, direct public node ingress closed, OIDC for humans + ServiceAccount tokens for automation. These are load-bearing.
- Routine control-plane replacement is **not** a supported operation; it is recovery-grade work gated by `allow_control_plane_replacement` in the Infra Up inputs.

## Repository layout

```
terraform/envs/prod/      Root Terraform composition (the only env). main.tf wires
                          modules; locals.tf renders per-node cloud-init; vars.tf inputs.
terraform/modules/        network · firewall · server · loadbalancer (reused for the API LB)
bootstrap/cloud-init/     node.yaml — the single role-conditional cloud-init (see below)
bootstrap/scripts/        break-glass: bootstrap.sh, install-platform.sh, get-kubeconfig.sh
                          (install-platform.sh is also what platform-up.yml runs)
platform/base/            namespaces, hcloud/CSI Secrets, NetworkPolicies, cluster-access
platform/helm-values/     Cilium / CCM / CSI / Traefik values
platform/argocd/          Argo CD Application manifests (reconciled from the home cluster)
.github/workflows/        the five supported control-surface workflows
tests/unit/ · tests/render/  static checks invoked by `make test`
docs/                     adr/ · arc42/ · lessons-learned/ · caveats-and-traps.md · recovery.md
DECISIONS.md AGENTS.md    macro design + operating-model constraints (read both)
```

## Common commands

```bash
make test                  # terraform fmt + validate + render + shellcheck. Run before commits.
make render                # render-only; outputs go in tests/render/output/ (gitignored)
make lint                  # superset of test focused on style
make fmt                   # terraform fmt -recursive

terraform -chdir=terraform/envs/prod init -backend=false
terraform -chdir=terraform/envs/prod validate
terraform -chdir=terraform/envs/prod fmt -check -recursive

./tests/unit/test_terraform.sh      # individual unit tests; safe to run standalone
./tests/unit/test_scripts.sh        # bootstrap script bash-syntax + function presence
./tests/render/validate-all.sh      # full manifest + Terraform render validation
```

There is no finer-grained "single test" runner — the suites are whole bash
scripts; run the one you care about directly (e.g. `./tests/unit/test_scripts.sh`).
Render validation must not produce persistent artifacts inside `terraform/envs/prod/`
(AGENTS.md rule); use a `/tmp` scratch dir for ad-hoc `templatefile` rendering.

## Architecture: four layers, bottom-up

```
┌─ Workloads ────────────── Argo CD (home cluster) → apps, CNPG, Redis, …
├─ Platform ─────────────── Cilium, Hetzner CCM/CSI, Traefik, base manifests
├─ k3s ──────────────────── 3 cp + N worker, embedded etcd, OIDC humans, SA bots
└─ Infrastructure ───────── Terraform: network, firewall, servers, API LB, volumes
```

Lower layers don't depend on higher ones. Recovery moves bottom-up.

**`bootstrap/cloud-init/node.yaml` is the single most important file.** It's one Terraform-templated cloud-init that produces three role variants (bootstrap CP, joining CP, worker) via `%{ if … }` directives, and a fourth via `restore_from_s3`. Several non-obvious things are encoded there:

- `ensure_private_nic` at the top of the bootstrap script self-heals the Hetzner private NIC race (ADR-0005). Don't remove it.
- The `restore_from_s3` branch installs k3s with **both** `INSTALL_K3S_SKIP_START=true` and `INSTALL_K3S_SKIP_ENABLE=true` (ADR-0004). A partial-failed `--cluster-reset` must NOT auto-rescue into an empty cluster.
- The restore branch downloads the snapshot via `mc` (ADR-0009), unzips it locally (ADR-0003), passes the **absolute path to the uncompressed file** to `--cluster-reset-restore-path` (avoids the k3s 1.35.x `decompressSnapshot` `filepath.Join` doubling bug), with `--node-ip=$NODE_PRIVATE_IP --advertise-address=$NODE_PRIVATE_IP --etcd-s3=false` (ADR-0010, ADR-0011).
- A sentinel `/var/lib/rancher/k3s/.recovery-restored` makes restore idempotent across reboots (ADR-0004).

Cloud-init is a YAML literal-block scalar (`content: |`); every line of the embedded bash must share the parent indent. **Heredocs (`<<EOF`) inside this script will break the YAML parse** — use inline shell variables or `printf` line-by-line instead. This trap has cost real cluster outages.

The bootstrap CP is `control-plane-01` (key index 0 in `local.control_plane_nodes`). It and only it sets `initialize_cluster=true` in the template. Don't reorder the map; the deterministic private IPs `10.0.0.10/11/12` depend on key ordering.

## Restore-from-S3 invariants

Because of the iteration history (see `docs/lessons-learned/2026-05-cluster-restore.md`), the restore code path is opinionated. Don't relax any of these without re-reading the ADR:

1. **Pre-decompress before invoking k3s.** k3s 1.35.x has a `filepath.Join` bug on `.zip` paths. Pass the uncompressed file path. (ADR-0003)
2. **Install with `SKIP_ENABLE` too.** Otherwise a failed restore + reboot creates a fresh empty cluster that workers/CPs happily join, silently destroying recovery. (ADR-0004)
3. **Pass `--node-ip` + `--advertise-address` to cluster-reset.** The cluster-reset process does NOT inherit them from the systemd unit. Without these, etcd records the public peer URL and the subsequent `k3s.service` start fails on member-list mismatch. (ADR-0011)
4. **Pass `--etcd-s3=false` on cluster-reset CLI.** `/etc/rancher/k3s/config.yaml` has `etcd-s3: true` for ongoing snapshots. Cluster-reset merges that config in and re-enters the broken S3 code path unless CLI overrides. (ADR-0010)
5. **The Infra Up workflow's `Terraform plan` step gates non-bootstrap CP `-replace` on API LB reachability.** Re-running restore against a healthy cluster MUST NOT destroy cp-2 + cp-3 in parallel — that breaks etcd quorum. Worker `-replace` is unconditional in restore mode because workers don't vote in etcd quorum and they need fresh CA pinning. (ADR-0006, ADR-0007)
6. **A successful Infra Up means a *healthy* cluster, not just a reachable one.** Two gates run after apply: `Wait for Kubernetes API to become ready` polls `/livez` until 200/401/403 (ADR-0008), then `Verify all expected nodes are Ready` asserts the exact Terraform node set (`${cluster}-cp-N` / `${cluster}-worker-N`) is Ready with a **live kubelet Lease** — using the Lease, not the Ready condition's `lastHeartbeatTime`, because the latter can be ~5 min stale on a healthy node (ADR-0016). The node gate needs the `REMOTE_CLUSTER_KUBECONFIG_B64` secret (shared with Verify Etcd Backups); without it the run warns and skips rather than failing. It fails closed to Ready-enforcement except in a genuine pre-CNI bootstrap (no Cilium DaemonSet → registration-only).

## Where decisions are recorded

- `DECISIONS.md` — macro design choices (server types, CNI, storage, security posture). Edit when the architecture shifts.
- `docs/arc42/` — 12-section structural reference with Mermaid diagrams. Read § 5 (Building Block View) and § 6 (Runtime View) before changing cloud-init or workflows.
- `docs/adr/` — Michael Nygard ADRs, **append-only**. To change a prior decision, write a new ADR that supersedes it.
- `docs/lessons-learned/` — chronological post-mortems. New entries when an operational issue costs more than ~1 PR cycle.
- `docs/caveats-and-traps.md` — **read this before editing cloud-init, Infra Up, the restore flow, or platform install.** Every known gotcha, indexed by symptom, each pointing at its ADR. This is the fastest way to avoid re-discovering an outage.
- `docs/recovery.md` — operator-facing runbook for the S3 restore flow.

When opening a PR that touches `bootstrap/cloud-init/node.yaml` or `.github/workflows/infra-up.yml` in a non-trivial way, write or update an ADR. The trigger is "could a future operator look at this and reasonably ask 'why?'".

## Tooling preferences

- Default shell on the operator's laptop is **zsh**. Bash tool commands run under zsh; `gh` often needs `zsh -i -c '…'` to pick up `GITHUB_TOKEN` from interactive shell profile.
- Terraform 1.9.x in the workflows; locally 1.6+ works for `validate`.
- Pinned k3s version is `v1.35.3+k3s1`. Several ADRs document workarounds for bugs specific to this version; revisit on upgrade.
- The recovery flow downloads `mc` from `dl.min.io` at restore time. Don't replace that with `aws-cli` (heavier) or hand-rolled curl SigV4 (fragile) without a good reason.
- Changes ship via small, focused PRs (split unrelated work). Two bots — **gemini-code-assist** and **chatgpt-codex-connector** (Codex) — auto-review every PR; address their comments before merge (Codex has caught real P1s here, often over *successive* rounds — re-check after each fix push, don't dismiss reflexively). The operator merges; PRs squash-merge, so rebase the next branch onto fresh `origin/main` afterward.
- **Don't stack a PR on another PR's branch.** A stacked PR targets that base branch, not `main` — merging it lands its changes on the base branch, so they silently never reach `main` (this swallowed the readiness-gate PR here; the base branch was not deleted, so GitHub did not auto-retarget it to `main`). Even when the base *is* deleted and GitHub retargets the stacked PR to `main`, squash-merging the base rewrote its commits under new hashes, so the stacked PR's diff is polluted by the original base commits — risking conflicts or duplicates. Branch each PR off `origin/main`; if two touch the same file, land the first, then cherry-pick the second onto fresh `main`.
- There are no required CI status checks; the two review bots are advisory. Merging is the operator's call.

## Things to avoid

- Adding bash heredocs inside the cloud-init `content: |` script — breaks YAML parse (see lessons-learned).
- Putting literal `${...}` in cloud-init template comments — Terraform tries to evaluate them. Escape with `$${...}` or use a different marker.
- Replacing both cp-2 AND cp-3 simultaneously while cp-1 is alone — breaks etcd quorum. ADR-0007 closes this in the workflow; don't undo it.
- Removing `ensure_private_nic` because "the netplan looks fine now" — the race is non-deterministic; it bit us specifically on CP replacement runs.
- Expecting a cloud-init edit to reach existing nodes. `user_data` is `ForceNew` but the server sets `ignore_changes=[user_data]` (ADR-0013); cloud-init only reaches a node on deliberate `terraform apply -replace=<node>`.
- Keying a per-node Terraform resource's `for_each` on `local.nodes` — that's a dependency cycle (nodes → user_data → resource → nodes). Key off the counts instead (see `random_password.node_password`).
- Adding a server-install flag (e.g. `--disable …`) to only one of the three k3s server blocks in cloud-init. All three must match; agents take none.
- Putting control planes in a `Service.type=LoadBalancer` target pool — a stale CP target fails the entire CCM LB sync. ADR-0014 excludes them via a Platform Up label.
- Re-reading a file you just edited "to verify"; the Edit tool surfaces errors and the harness tracks file state.

## When in doubt

Read the failing log carefully, then read the upstream source (k3s, etcd, Cilium, Hetzner provider) before committing a fix. The May 2026 restore arc burned 10 PRs in part because we kept committing guesses instead of fetching the source for the specific error. The `WebFetch` tool against `raw.githubusercontent.com` is fast and ungated.
