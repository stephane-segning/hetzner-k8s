# 2026-05 — Cluster restore from S3: ten PRs, six bugs, what to do differently

## Summary

The production k3s cluster (`ssegning-hetzner-k3s`, 3 cp + 3 worker) lost
its control planes in late May 2026. Etcd snapshots in S3 were intact.
Recovery should have been one PR + one workflow run. It took **ten merged
PRs and one manual `cluster-reset` over SSH** to land a clean cluster.

Six distinct bugs / design gaps stacked on top of each other. Each one
was individually small. The compounding factor was that we kept committing
each fix without first reading the upstream source for the next failure
mode, so each fix uncovered the next one.

This document captures the chronological arc and what we should do
differently next time.

---

## Timeline

| PR  | What it tried to fix                                                      | What it produced                                                            |
|-----|---------------------------------------------------------------------------|------------------------------------------------------------------------------|
| #5  | Add an S3 restore branch to cloud-init + Infra Up workflow inputs         | Cloud-init **failed to parse** because the bash heredoc body sat at column 1 in a YAML literal-block scalar |
| #6  | Force-replace non-bootstrap CPs on restore (so they don't keep stale etcd) | Correct on first restore; broke etcd quorum on re-runs (fixed later in #14)  |
| #7  | Replace heredoc env file with inline shell vars (fixes #5)                | Cloud-init parses. Cluster-reset invocation still fails with doubled-path on `.zip` snapshots |
| #8  | Bring up the Hetzner private NIC explicitly; download snapshot via `mc`; add `/livez` gate | Three real fixes; cluster-reset still hits the doubled-path bug              |
| #9  | Pass snapshot **basename** instead of absolute path to cluster-reset      | Different failure mode: `etcd: snapshot path does not exist` (k3s chdir's before the stat) |
| #10 | `cd` to snapshots dir before invoking k3s, then pass basename             | Same `snapshot path does not exist` error — k3s' working directory after chdir is not the snapshots dir |
| #11 | **Pre-decompress the snapshot with `unzip`**, pass the absolute path of the uncompressed file; add `INSTALL_K3S_SKIP_ENABLE=true` + sentinel | Cluster-reset finally completes. 22 MB etcd data loaded, defrag completed. New failure: `k3s.service` can't start because etcd member list has the public peer URL |
| #12 | Pass `--node-ip` / `--advertise-address` to the cluster-reset invocation  | Cluster-reset records the private peer URL. cp-1 comes up cleanly with the restored data. Workers loop on `x509: certificate signed by unknown authority` |
| #13 | Extend `-replace` to workers when `restore_from_s3=true`                  | First restore now works end-to-end. Re-runs (against an already-restored cluster) destroy cp-2 and cp-3 simultaneously, breaking etcd quorum |
| #14 | Gate non-bootstrap CP `-replace` on API LB reachability                   | Re-runs leave healthy CPs untouched. Quorum-break trap closed.              |

Between PR #13 and PR #14 the operator had to manually `systemctl stop
k3s; k3s server --cluster-reset; systemctl start k3s` on cp-1 to forget
the dead etcd members and restore quorum. This is the "manual SSH work"
that the GH-Actions-only operating model is specifically designed to
prevent, and is the one operational regression of the whole arc.

---

## The six underlying problems

### 1. Cloud-init YAML literal-block vs bash heredoc indentation conflict

The bootstrap script lives in `bootstrap/cloud-init/node.yaml` inside a
`content: |` block. Every line of that block must share the parent's
indent (6 spaces in our template). A bash `<<'EOF' ... EOF` heredoc
inside the script must have its **closing word at column 0** or bash
never finds the terminator. The two semantics are incompatible.

**Symptom:** cloud-init reports `Failed loading yaml blob. Invalid format
at line 116 column 1: ... could not find expected ':'`. The entire
bootstrap script fails to load. None of the cloud-init runcmds run. The
node looks like it booted normally but k3s never installs.

**Diagnostic signature on the LB:** TLS handshake succeeds at TCP, then
the LB closes the connection because no target is healthy — `openssl
s_client` reports "no peer certificate available".

**Mitigation:** Don't put bash heredocs inside the literal-block scalar.
Use `printf` line-by-line to build files (see `ensure_private_nic`'s
netplan write), or use inline shell variables for credentials (see the
restore branch).

**Where it hides:** anywhere a contributor reaches for `cat > /file <<EOF`
inside the cloud-init template. There's no compile-time warning;
`terraform plan` is happy; only the runtime parse fails on the real VM.

### 2. Hetzner private NIC race with cloud-init's netplan rendering

`hcloud_server { network {} }` attaches the server to the private network
via Hetzner API as part of server creation. On some boots, the second NIC
(`enp7s0` after udev rename) exists at `ip link` level before cloud-init
runs netplan, but on other boots the attachment is slightly slower and
netplan is written with only `eth0`. The private NIC then stays `DOWN`
indefinitely. The configured `--node-ip=10.0.0.X` is unassignable.

**Symptom:** k3s fails to start with
`listen tcp 10.0.0.10:2380: bind: cannot assign requested address`. The
node is otherwise reachable on its public IP.

**Mitigation:** ADR-0005. Cloud-init writes its own
`60-private.yaml` matching the second NIC by MAC and runs
`netplan apply`. Self-healing across reboots, idempotent.

### 3. k3s 1.35.x `decompressSnapshot` filepath.Join bug

[`pkg/etcd/snapshot.go::decompressSnapshot`](https://github.com/k3s-io/k3s/blob/master/pkg/etcd/snapshot.go)
does `filepath.Join(snapshotDir, snapshotFilename)`. The caller in
[`pkg/etcd/etcd.go::Restore`](https://github.com/k3s-io/k3s/blob/master/pkg/etcd/etcd.go)
passes an absolute `ClusterResetRestorePath` as the second arg. Go's
`filepath.Join` does not strip the leading slash from an absolute second
arg, so `Join("/a/b", "/a/b/c.zip") == "/a/b/a/b/c.zip"`. The bug only
fires for `.zip` paths because that's the only branch that calls
`decompressSnapshot` — uncompressed paths take the verbatim `else`
branch.

**Symptom:** `open /var/lib/rancher/k3s/server/db/snapshots/var/lib/rancher/k3s/server/db/snapshots/etcd-snapshot-<...>.zip: no such file or directory`.

**Mitigation:** ADR-0003. Pre-decompress with `unzip`, pass the absolute
path of the uncompressed file. Routes through the safe `else` branch.

**Lesson:** when guessing at a failure mode, **read the source first**.
We burned PRs #9, #10, #11 trying various combinations of basename / abs /
cd before fetching the actual k3s source. Once we read it, the fix was
one line of cloud-init.

### 4. `--cluster-reset` is a separate process from `k3s.service`

The `k3s server --cluster-reset --cluster-reset-restore-path=...` we run
during restore is not the same process that systemd later manages. It
does NOT inherit `--node-ip` / `--advertise-address` / other flags from
`/etc/systemd/system/k3s.service`. It only sees the CLI args we pass and
`/etc/rancher/k3s/config.yaml`. Anything important must be passed twice
(install command + cluster-reset command).

**Symptom:** restored etcd records cp-1's peer URL as the public IP
(`https://159.69.22.206:2380`). `systemctl start k3s` then runs with
`--node-ip=10.0.0.10`, etcd notices the mismatch, refuses to join.

**Mitigation:** ADR-0011. Pass `--node-ip` and `--advertise-address`
explicitly to the cluster-reset CLI.

### 5. `INSTALL_K3S_SKIP_ENABLE=true` is required for safe restore

The k3s install script leaves the systemd unit `enabled` by default. If
`--cluster-reset` partially fails (writes certs, doesn't populate etcd
fully), the next reboot or manual `systemctl start k3s` would silently
bootstrap a **brand new empty cluster** on top of the partial state —
exactly what happened in one of our iterations, leaving the operator
with six nodes joined to a fresh empty cluster.

**Mitigation:** ADR-0004. Install with
`INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true`. Only
`systemctl enable && systemctl start` after `--cluster-reset` returns 0.

Combined with a sentinel file `/var/lib/rancher/k3s/.recovery-restored`
so re-runs of cloud-init don't re-enter cluster-reset on populated etcd.

### 6. Etcd quorum breaks on parallel non-bootstrap CP destroy

Etcd does not automatically remove unreachable members from its config.
If Terraform destroys cp-2 and cp-3 simultaneously, cp-1's etcd sees
`{cp-1, cp-2-old, cp-3-old}` with 2 unreachable — 1 of 3 voters,
**no quorum**. New cp-2 and cp-3 trying to join can't be added because
adding a member is itself a write that requires quorum.

This bit us in PR #13: the workflow's `-replace` of non-bootstrap CPs
was unconditional whenever `restore_from_s3=true`. On the *first*
restore that's correct (the old cp-2/cp-3 had stale etcd data). On a
*re-run* it's catastrophic.

Recovery from the broken state required ssh'ing to cp-1 and running
`k3s server --cluster-reset` (no restore path) to forget the dead
members.

**Mitigation:** ADR-0007. Probe the API LB before computing
`-replace`; if reachable, skip non-bootstrap CP replacement.

---

## What we'd do differently

### Read upstream source before committing the next fix

We had four iterations between "abs path" and "basename" trying to find
the right `--cluster-reset-restore-path` value, when the actual answer
required reading two functions in the k3s repo. Pattern to enforce: when
the operator runs an Infra Up and it fails inside a vendored tool (k3s,
etcd, Cilium), **next step is to fetch the source for the specific error
message**, not to guess and commit.

The WebFetch / WebSearch tooling for k3s' public source on GitHub is
fast and ungated. There is no excuse to guess in this loop.

### Probe the cluster from the workflow side, not just from inside cloud-init

PR #8's `/livez` gate was the right design but came late. Adding it earlier
would have prevented the "Infra Up green / cluster dead" cycle from
PRs #5-#10. Lesson: **a workflow that touches a cluster should validate
the cluster is up before reporting success.** Self-validation is cheap
and saves all downstream "did it actually work" debugging.

### Sentinel-or-equivalent state needs to be visible across processes

The sentinel approach (ADR-0004) is sound but ad-hoc. A more principled
approach would be: cloud-init queries a single source of truth (a label
on the Hetzner server, an annotation on a k8s Node, a file under
`/etc/rancher/k3s/`) and decides based on that what mode to run in. The
sentinel file works but is one of several places state lives; future
iterations should consider consolidating.

### Quorum-safe destructive operations need to be explicit, not implicit

PR #13's `-replace` was an implicit "make everything fresh" move that
worked on first restore and was destructive on re-runs. The right design
gates expensive cluster-membership operations on **explicit observable
state** (does the API answer? does etcd report N healthy members?) — not
on a workflow input. ADR-0007 fixes this for our specific case; the
generalization is: "when destroying a CP, first probe what's there".

### Worker re-bootstrapping has a different blast radius than CP

Workers don't participate in etcd quorum and can be replaced in parallel
without correctness concern. CPs cannot. Treating them as one class led
to PR #13's quorum break. Different recovery domain → different
`-replace` logic. ADR-0006 and ADR-0007 split them.

### YAML + bash inline = read carefully

The cloud-init template went through three rounds of "the YAML doesn't
parse because a comment had `${...}` in it" or "the YAML doesn't parse
because the heredoc body is at column 0". These are cheap traps that
better tooling would catch (e.g., a render-then-yamllint step that
exercises the templated values with realistic content). We have basic
YAML parse checks; we don't have a "render with vars, parse, lint"
step. Worth adding.

---

## Artifacts

- Restore workflow: `.github/workflows/infra-up.yml` (the `Validate
  restore inputs`, `Terraform plan` and `Wait for Kubernetes API to
  become ready` steps).
- Cloud-init restore branch: `bootstrap/cloud-init/node.yaml` (the
  `restore_from_s3` block within the bootstrap CP path).
- Recovery runbook: [`docs/recovery.md`](../recovery.md) — operator-
  facing procedure.
- Related ADRs: [0002](../adr/0002-restore-etcd-from-s3-via-infra-up.md),
  [0003](../adr/0003-pre-decompress-snapshot-before-cluster-reset.md),
  [0004](../adr/0004-idempotent-restore-skip-enable-sentinel.md),
  [0005](../adr/0005-bring-up-private-nic-in-cloud-init.md),
  [0006](../adr/0006-force-replace-workers-on-restore.md),
  [0007](../adr/0007-gate-cp-replace-on-api-reachability.md),
  [0008](../adr/0008-self-validate-infra-up-via-livez-gate.md),
  [0009](../adr/0009-mc-for-inline-s3-download-during-restore.md),
  [0010](../adr/0010-etcd-s3-false-on-cluster-reset.md),
  [0011](../adr/0011-node-ip-on-cluster-reset.md).
- PRs that landed the fixes: #5, #6, #7, #8, #9, #10, #11, #12, #13, #14.
