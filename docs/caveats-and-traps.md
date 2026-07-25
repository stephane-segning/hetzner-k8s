# Caveats & Traps

A single place that consolidates every non-obvious gotcha discovered
operating this cluster. If you are about to touch cloud-init, the Infra Up
workflow, the restore flow, or the platform install, **skim this first** —
most of these cost at least one PR cycle (some cost cluster outages) to
re-discover.

Each entry: the **trap**, the **symptom** you'd see, the **fix / rule**,
and a pointer to the authoritative ADR or doc.

Legend: 🧨 = has caused a real outage/incident · ⚠️ = will bite on the
next relevant change if ignored · 🩹 = break-glass remediation exists.

---

## 1. Cloud-init templating (`bootstrap/cloud-init/node.yaml`)

This file is a Terraform `templatefile` **and** a YAML literal-block scalar
(`content: |`) **and** contains a bash script. Three languages, three sets
of escaping rules, in one file.

### 1.1 🧨 Bash heredocs break the YAML parse
- **Trap:** a bash `<<EOF … EOF` heredoc inside the `content: |` block. The
  heredoc body must start at column 0 for bash, but YAML requires every
  line of the literal block to share the parent indent. They are
  irreconcilable.
- **Symptom:** `cloud-init status --long` →
  `Failed loading yaml blob. Invalid format ... could not find expected ':'`.
  The **entire** bootstrap script silently never runs; k3s never installs;
  the node looks booted but has no `:6443` listener and the API LB target
  is unhealthy.
- **Fix / rule:** never use heredocs here. Build files with `printf`
  line-by-line (see `ensure_private_nic`'s netplan write) or use inline
  shell variables (see the restore branch's S3 creds).
- **Ref:** lessons-learned [2026-05](lessons-learned/2026-05-cluster-restore.md) §1.

### 1.2 ⚠️ Literal `${...}` in a comment is evaluated by Terraform
- **Trap:** writing a bash parameter expansion like `${VAR##*/}` or an
  example `${...}` in a *comment* inside the template. Terraform's
  `templatefile` evaluates `${...}` everywhere, including comments, and
  fails with `Invalid character` / `vars map does not contain key`.
- **Symptom:** `terraform plan`/render fails on a line that is "just a
  comment".
- **Fix / rule:** escape as `$${...}` (Terraform emits a literal `${...}`),
  or reword the comment to avoid the sequence.

### 1.3 ⚠️ `set -o pipefail` + `grep` with no match aborts the script
- **Trap:** the bootstrap script runs `set -euo pipefail`. A pipeline whose
  last meaningful stage is `grep` returns non-zero when there's no match,
  aborting the whole script — even when "no match yet" is the expected
  transient state (e.g. the private NIC hasn't attached on the first poll).
- **Symptom:** bootstrap exits early during the exact race a retry loop was
  meant to handle.
- **Fix / rule:** wrap such stages `{ grep -vE '…' || true; }`. See
  `ensure_private_nic`.
- **Ref:** ADR-0005.

### 1.4 ⚠️ The three k3s **server** blocks must stay in sync
- **Trap:** the template has three server-install code paths (fresh
  `--cluster-init`, joining CP, restore-mode install). A flag added to one
  (e.g. `--disable metrics-server`, `--disable local-storage`) must be
  added to all three. Agents (workers) take none of the `--disable` flags.
- **Symptom:** inconsistent node behavior depending on how a node was
  provisioned.
- **Fix / rule:** when editing server flags, grep for all `--disable` /
  `INSTALL_K3S_EXEC="server"` blocks and change every one.
- **Ref:** ADR-0015 § Consequences; arc42 § 5.3.

---

## 2. k3s etcd restore (`restore_from_s3` path)

The restore code path is opinionated because k3s `v1.35.3+k3s1` has several
sharp edges. Don't relax any of these without re-reading the ADR.

### 2.1 🧨 `decompressSnapshot` doubles the path for `.zip` snapshots
- **Trap:** passing an absolute `.zip` path (or letting k3s' `--etcd-s3`
  download it) to `--cluster-reset-restore-path`. k3s'
  `decompressSnapshot` does `filepath.Join(snapshotsDir, restorePath)`, and
  Go's `filepath.Join` does NOT strip the leading slash of an absolute
  second arg, producing `/var/lib/.../snapshots/var/lib/.../snapshots/<f>.zip`.
- **Symptom:**
  `open /var/lib/rancher/k3s/server/db/snapshots/var/lib/rancher/k3s/server/db/snapshots/<file>.zip: no such file`.
- **Fix / rule:** pre-decompress with `unzip` and pass the absolute path of
  the **uncompressed** file (the non-`.zip` branch of `Restore()` uses the
  path verbatim). Passing a bare basename does *not* work either (k3s
  chdir's before the stat).
- **Ref:** ADR-0003.

### 2.2 🧨 `config.yaml`'s `etcd-s3: true` is merged into cluster-reset
- **Trap:** the regular service has `etcd-s3: true` in
  `/etc/rancher/k3s/config.yaml` for ongoing snapshots. k3s merges
  config.yaml into the one-shot `--cluster-reset` invocation too, dragging
  it back onto the broken S3-download path (2.1) even though you downloaded
  locally.
- **Fix / rule:** pass `--etcd-s3=false` on the cluster-reset CLI to
  override config.yaml for that one run.
- **Ref:** ADR-0010.

### 2.3 🧨 cluster-reset doesn't inherit `--node-ip` from the systemd unit
- **Trap:** the `--cluster-reset` process is separate from the
  systemd-managed `k3s.service` and does NOT read the unit's flags. Without
  `--node-ip` / `--advertise-address`, etcd records the node's **public**
  IP (default route) as the member peer URL.
- **Symptom:** after restore, `k3s.service` is stuck `activating` with
  `this server is not a member of the etcd cluster. Found [...=https://<public>:2380], expect ...=https://<private>:2380`.
- **Fix / rule:** pass `--node-ip` and `--advertise-address` to the
  cluster-reset CLI too (and to the install — both, separately).
- **Ref:** ADR-0011.

### 2.4 🧨 In-cluster S3 secret is unavailable during restore
- **Trap:** the `k3s-etcd-snapshot-s3-config` Secret lives in the very etcd
  you're restoring, so you can't use it to fetch the snapshot.
- **Fix / rule:** download the snapshot yourself with `mc`, S3 creds passed
  inline via cloud-init (rendered from `TF_VAR_etcd_s3_*`). Creds go in a
  `mktemp -d --config-dir` with a `trap '…' EXIT` so they're shredded even
  on failure.
- **Ref:** ADR-0009.

### 2.5 🧨 A partial cluster-reset auto-rescues into an EMPTY cluster
- **Trap:** if `--cluster-reset` partially fails and `k3s.service` is
  *enabled*, the next boot (or a manual `systemctl start k3s`) sees the
  half-populated data dir, decides it's a normal start, and bootstraps a
  **brand-new empty cluster**. Workers and other CPs then happily join the
  empty cluster — silently destroying the recovery while your snapshot sits
  untouched in S3.
- **Symptom:** cluster comes "up" but every workload is gone; `kubectl get
  ns` shows only the defaults.
- **Fix / rule:** install with `INSTALL_K3S_SKIP_START=true` **and**
  `INSTALL_K3S_SKIP_ENABLE=true`; only `systemctl enable && start` *after*
  cluster-reset returns 0. A sentinel `/var/lib/rancher/k3s/.recovery-restored`
  makes re-runs skip the reset.
- **Ref:** ADR-0004.

### 2.6 🧨 Re-running restore destroys etcd quorum
- **Trap:** the workflow force-`-replace`s non-bootstrap CPs in restore
  mode. On a *re-run* against an already-restored, healthy cluster, that
  tears down cp-2 + cp-3 in parallel, leaving cp-1 as 1-of-3 voters. Etcd
  doesn't auto-remove dead members, so there's no quorum, and new members
  can't be added (adding a member is itself a quorum write).
- **Symptom:** API LB returns 503/000; cp-1 logs
  `authentication handshake failed: context deadline exceeded` and
  `dial tcp 10.0.0.1x:2380: connect: connection refused` for the dead CPs.
- **Fix / rule:** the Infra Up `Terraform plan` step probes `/livez` first.
  If the cluster is reachable, it replaces **workers only** and spares the
  CPs. Only an unreachable cluster ("first restore") replaces all CPs.
- 🩹 **Break-glass if you hit it:** on cp-1, `systemctl stop k3s; k3s server
  --cluster-reset --token <tok> --node-ip <priv> --advertise-address <priv>
  --etcd-s3=false; systemctl start k3s` to forget the dead members.
- **Ref:** ADR-0006, ADR-0007; lessons-learned 2026-05.

### 2.7 ⚠️ Remember to leave `restore_from_s3=false` afterward
- **Trap:** running Infra Up with `restore_from_s3=true` once and leaving it
  set. The sentinel (2.5) + the reachability gate (2.6) make re-runs safe
  now, but it's still cleaner to default it off.
- **Fix / rule:** `restore_from_s3` is a `workflow_dispatch` input that
  defaults to `false`; just don't pass `true` on routine runs.

---

## 3. Hetzner networking

### 3.1 🧨 Private NIC race leaves `enp7s0` DOWN
- **Trap:** the Hetzner private network attaches in parallel with
  cloud-init's network rendering. On a lost race, netplan is written with
  only `eth0`; the private NIC exists but is DOWN with no IP.
- **Symptom:** k3s fails to start with
  `listen tcp 10.0.0.10:2380: bind: cannot assign requested address`. Node
  reachable on its public IP only.
- **Fix / rule:** `ensure_private_nic` in cloud-init detects the NIC by
  exclusion, writes `/etc/netplan/60-private.yaml` matching by MAC, and
  `netplan apply`s. Idempotent, runs on every boot, all roles.
- **Ref:** ADR-0005.

### 3.2 ⚠️ The `EXTERNAL-IP` column in `kubectl get no -o wide` lies
- **Trap:** after reboots/replacements you may see workers showing a
  control-plane's public IP (or duplicates) in the `EXTERNAL-IP` column.
- **Symptom:** looks like a serious addressing bug.
- **Fix / rule:** it's just Hetzner CCM's cached address mapping not yet
  reconciled. **Don't chase it.** Confirm real IPs with
  `ssh root@<ip> 'hostname; ip -4 -o addr show enp7s0'` or
  `kubectl get no -o json`. It self-corrects, or nudge with
  `kubectl -n kube-system rollout restart deploy hcloud-cloud-controller-manager`.
- **Ref:** lessons-learned 2026-06-02.

### 3.3 🧨 A stale CP target fails the ENTIRE ingress LB sync
- **Trap:** if a control plane is a target of a `Service.type=LoadBalancer`
  and its `providerID` goes stale (e.g. after recreation), Hetzner CCM's
  all-or-nothing reconcile fails for the whole LB.
- **Symptom:** the Service never gets an address; CCM logs
  `ReconcileHCLBTargets: ... cloud target was not found` /
  `resolve_cloud_private_targets_error`.
- **Fix / rule:** control planes are labelled
  `node.kubernetes.io/exclude-from-external-load-balancers` by Platform Up
  so only workers are LB targets. Re-run Platform Up if a new CP joined
  without the label.
- **Ref:** ADR-0014.

---

## 4. Node identity (CA / node-password)

### 4.1 🧨 Worker CA pinning rejects the restored cluster
- **Trap:** `k3s-agent` pins the cluster CA fingerprint at first join. A
  worker that joined a *different* cluster era (e.g. the empty cluster from
  a failed restore) rejects the restored cluster's certs.
- **Symptom:** `tls: failed to verify certificate: x509: certificate signed
  by unknown authority`; worker NotReady.
- **Fix / rule:** restore mode force-`-replace`s all workers so they
  bootstrap fresh against the current CA. (Workers don't vote in etcd
  quorum, so parallel replacement is safe — unlike CPs, see 2.6.)
- **Ref:** ADR-0006.

### 4.2 🧨 Node-password mismatch on reboot/replace/restore
- **Trap:** k3s stores `hash(node-password)` in a Secret
  `<nodename>.node-password.k3s` and rejects joins that don't match. A
  fresh disk (`-replace`) or a restore re-introducing an older-era Secret
  makes the on-disk password and the Secret drift apart.
- **Symptom:** node NotReady, `Kubelet stopped posting node status`; agent
  logs `Node password rejected, ... /etc/rancher/node/password may not
  match server node-passwd entry`.
- **Fix / rule:** cloud-init writes a **per-node** password held in
  Terraform state (`random_password.node_password`) — stable across
  reboot/replace/restore, independent of the join token.
- 🩹 **Break-glass:** delete the affected node's Secret
  (`kubectl -n kube-system delete secret <node>.node-password.k3s`) and the
  agent re-registers in ~30s. **But** don't do delete-only on a *pre-ADR-0012*
  running node — it re-pins the old random password and a later `-replace`
  still mismatches; see roadmap N-5 for the correct eager migration.
- **Ref:** ADR-0012; lessons-learned 2026-06-02.

### 4.3 ⚠️ `node.kubernetes.io/*` labels can't come from k3s `--node-label`
- **Trap:** kubelet runs under NodeRestriction and may not self-apply
  labels in the `node.kubernetes.io/*` / `kubernetes.io/*` namespaces.
- **Symptom:** k3s rejects `--node-label node.kubernetes.io/...`.
- **Fix / rule:** apply such labels post-bootstrap with an admin credential
  (`kubectl label`), e.g. the LB-exclusion label in Platform Up.
- **Ref:** ADR-0014.

---

## 5. Terraform / Infra Up deployment model

### 5.1 🧨 `user_data` is `ForceNew` — cloud-init edits want to replace every node
- **Trap:** `user_data` on `hcloud_server` is `ForceNew`. Any cloud-init
  edit changes every node's `user_data`, so a routine `terraform plan`
  wants to destroy+recreate **all** servers at once. The CP-replacement
  guard then fails the workflow, and replacing all CPs together would break
  etcd quorum.
- **Symptom:** the next routine Infra Up (run for any unrelated reason)
  fails at `Guard control-plane replacements`.
- **Fix / rule:** the server resource sets `lifecycle { ignore_changes =
  [user_data] }`. cloud-init only runs at first boot anyway, so edits never
  reach live nodes; roll changes out deliberately via
  `terraform apply -replace=<node>` (workers freely; CPs one at a time;
  restore flow `-replace`s the bootstrap CP itself).
- **Ref:** ADR-0013.

### 5.2 ⚠️ Editing cloud-init does NOT change running nodes
- **Trap:** a corollary of 5.1 + `ignore_changes`. You edit `node.yaml`,
  merge, and expect existing nodes to pick it up. They don't.
- **Fix / rule:** to apply a cloud-init change to an existing node, you
  must deliberately `-replace` that node. Document the intent; expect
  config drift between "what node.yaml says" and "what a long-lived node
  actually booted with".
- **Ref:** ADR-0013; arc42 § 5.3.

### 5.3 ⚠️ The CP-replacement guard is a feature, not a bug
- **Trap:** seeing Infra Up fail with "Refusing to apply because Terraform
  plans to replace or delete control-plane servers" and reaching for
  `allow_control_plane_replacement=true` reflexively.
- **Fix / rule:** that guard exists to stop accidental CP loss. Before
  overriding it, understand *why* the plan wants to replace a CP (usually
  unintended `user_data` drift — which 5.1 should now prevent — or a
  genuine recovery). Routine control-plane replacement is not supported.
- **Ref:** AGENTS.md; ADR-0007.

### 5.4 🧨 Dependency cycle if you key resources off `local.nodes`
- **Trap:** `local.nodes` includes each node's `user_data`, which now
  references `random_password.node_password`. Keying that resource's
  `for_each` on `local.nodes` creates a cycle
  (nodes → user_data → node_password → nodes).
- **Fix / rule:** key per-node resources off the **counts**
  (`toset([for i in range(var.control_plane_count) : format("control-plane-%02d", i+1)])`,
  same for workers), never off `local.nodes`.
- **Ref:** `terraform/envs/prod/main.tf` (`random_password.node_password`).

### 5.5 ⚠️ `--cluster-init` ordering / deterministic IPs
- **Trap:** `control-plane-01` (key index 0) is the only node with
  `initialize_cluster=true`. Private IPs `10.0.0.10/11/12` are derived from
  the key ordering of `local.control_plane_nodes`.
- **Fix / rule:** don't reorder the node map or change the key format; the
  deterministic IPs and the bootstrap-CP designation depend on it.
- **Ref:** arc42 § 5.2.

---

## 6. Platform install (`bootstrap/scripts/install-platform.sh`)

### 6.1 ⚠️ Metrics-server name collision breaks `kubectl top` + HPA
- **Trap:** k3s' bundled single-replica `metrics-server` collides on the
  `metrics-server` name with the platform's HA chart. Bundled pods
  (`k8s-app=metrics-server`) keep running; the chart Service
  (`app.kubernetes.io/*` selector) gets no endpoints.
- **Symptom:** `v1beta1.metrics.k8s.io` APIService `Available=False`;
  `kubectl top` and HPA metrics fail cluster-wide.
- **Fix / rule:** `--disable metrics-server` on all k3s servers (ADR-0015).
  ⚠️ On a live cluster you must *also* delete the bundled
  `deployment/metrics-server` + `service/metrics-server` once, so the
  chart's resources reconcile.
- **Ref:** ADR-0015.

### 6.2 ⚠️ Platform Up re-asserts cluster-side state; run it after recovery
- **Trap:** the LB-exclusion label (ADR-0014) and the
  `k3s-etcd-snapshot-s3-config` Secret are applied by Platform Up, not by
  Terraform or k3s. After a restore or a new CP join, they may be missing.
- **Fix / rule:** run Platform Up after any recovery; it's idempotent and
  re-asserts these.
- **Ref:** ADR-0014, ADR-0009.

---

## 7. Operational / tooling

### 7.1 `gh` needs an interactive zsh to see the token
- **Trap:** `gh` commands fail unauthenticated under a plain non-interactive
  shell.
- **Fix / rule:** run via `zsh -i -c '…'` to pick up `GITHUB_TOKEN` from the
  interactive profile.

### 7.2 Render validation must not leave artifacts in `terraform/envs/prod/`
- **Trap:** running render/validate that writes scratch files into the prod
  env dir.
- **Fix / rule:** AGENTS.md rule; render outputs go in
  `tests/render/output/` (gitignored). Use a `/tmp` scratch dir for
  ad-hoc `templatefile` rendering.

### 7.3 Read the upstream source before guessing
- **Trap:** the May 2026 restore arc burned ~4 PRs guessing at the
  `--cluster-reset-restore-path` value before anyone read the k3s source.
- **Fix / rule:** when a vendored tool (k3s, etcd, Cilium, the hcloud
  provider) fails with a specific error, fetch its source
  (`raw.githubusercontent.com` via WebFetch is fast and ungated) before
  committing a fix.
- **Ref:** lessons-learned 2026-05.

---

## 8. Server resize (`server_type` change / Hetzner rescale)

`server_type` is **not** `ForceNew` in the hcloud provider — changing it calls
`Server.ChangeType()` (power off → resize → power on), keeping the server ID.
That makes resizing far safer than replacement (no cloud-init re-run, no etcd
rejoin), but the power cycle has its own traps.

### 8.1 🧨 A rescale can leave `/etc/fstab` EMPTY → `/` stays read-only
- **Trap:** the rescale's power-off can catch `/etc/fstab` mid-rewrite,
  leaving it **0 bytes**. On the next boot the kernel cmdline mounts `/` as
  `ro` (it always does — `root=UUID=… ro`), and `systemd-remount-fs` is what
  flips it to `rw` **by reading fstab**. With an empty fstab it has nothing to
  act on, exits `SUCCESS` having done nothing, and `/` stays read-only
  forever.
- **Symptom:** k3s crash-loops with a message that blames TLS, not the disk:
  `level=fatal msg="Error: preparing server: failed to generate server
  dependencies: remove /var/lib/rancher/k3s/server/tls/client-kube-proxy.crt:
  read-only file system"`. Alongside it, a pile of unrelated-looking failed
  units (`cloud-init` ×4, `snapd`, `fail2ban`, `grub-common`,
  `k3s-bootstrap`) — all downstream of the same read-only root. **SSH still
  works**, which makes it look like a k3s bug.
- **It is a race, not a certainty.** Three identical CPs were rescaled
  together on 2026-07-25; only cp-1 hit it. Assume it *may* happen on any
  rescale; never rescale two etcd voters at once.
- **First, rule out real disk damage** (30 seconds, and it changes the fix
  completely):

  ```bash
  findmnt -no OPTIONS /                 # ro,relatime  → confirms the symptom
  dmesg -T | grep -iE "EXT4-fs|I/O error"   # expect NOTHING
  tune2fs -l /dev/sda1 | grep "Filesystem state"   # expect: clean
  stat -c %s /etc/fstab                 # 0 → this trap
  ```

  `Filesystem state: clean` + no I/O errors ⇒ the disk is fine and `fsck`/
  rescue mode is **not** needed. Do not reach for a rebuild.
- **🩹 Fix (derive the UUIDs from the node itself, never copy another node's
  fstab blindly):**

  ```bash
  mount -o remount,rw /
  ROOT_UUID=$(blkid -s UUID -o value /dev/sda1)
  EFI_UUID=$(blkid -s UUID -o value /dev/sda15)
  printf "/dev/disk/by-uuid/%s / ext4 defaults 0 1\n" "$ROOT_UUID" > /etc/fstab
  printf "/dev/disk/by-uuid/%s /boot/efi vfat defaults 0 1\n" "$EFI_UUID" >> /etc/fstab
  findmnt --verify --fstab          # MUST report 0 parse errors before you reboot
  systemctl daemon-reload
  systemctl reset-failed k3s        # clears the restart-limit penalty
  systemctl restart k3s
  ```

  Then **reboot once, deliberately, while quorum is healthy** to prove fstab
  persists — far better than discovering it during the next incident. The
  previously-failed units recover by themselves once `/` is writable.
- **Note:** the Hetzner Ubuntu image uses the *same* root filesystem UUID on
  every node (it is baked into the image), so a neighbour's fstab looks
  correct. Use the local `blkid` anyway — `/boot/efi` genuinely differs.
- **Ref:** ADR-0018, lessons-learned 2026-07-25.

### 8.2 ⚠️ The `cpx22`/`cpx32` default lives in FOUR places
- **Trap:** changing `control_plane_server_type` in `vars.tf` alone. All three
  workflows carry their own fallback
  (`${{ vars.TF_CONTROL_PLANE_SERVER_TYPE || 'cpx32' }}`), and a GitHub repo
  **variable** of the same name overrides both.
- **Symptom:** the next Infra Up silently *rescales the control planes back
  down*, re-creating the memory starvation of ADR-0018.
- **Fix / rule:** change `terraform/envs/prod/vars.tf`,
  `infra-up.yml`, `infra-destroy.yml`, `platform-up.yml`, **and** the repo
  variable together.

### 8.3 ⚠️ `keep_disk` decides whether a resize is reversible
- **Trap:** the hcloud provider defaults `keep_disk = false`, which upgrades
  the disk as part of the resize. **A disk upgrade is one-way** — once it has
  happened the server can never be rescaled *down* again.
- **Fix / rule:** if you want the resize to stay reversible, set
  `keep_disk = true` (the module does not expose it today — it would need a
  new variable). The 2026-07-25 CPX22→CPX32 rescale happened to leave the
  disk at 80 GB, so it remains reversible.

---

## Quick index by symptom

| You see…                                                            | Go to |
|---------------------------------------------------------------------|-------|
| `Failed loading yaml blob ... could not find expected ':'`          | 1.1   |
| `terraform … Invalid character` on a comment line                   | 1.2   |
| `open …/snapshots/…/snapshots/…zip: no such file`                   | 2.1   |
| `this server is not a member of the etcd cluster`                   | 2.3   |
| restored cluster is empty / workloads gone                           | 2.5   |
| API LB 503; `authentication handshake failed` on cp-1               | 2.6   |
| `bind: cannot assign requested address` on :2380                     | 3.1   |
| worker shows a CP's IP in `EXTERNAL-IP`                              | 3.2   |
| Service.type=LoadBalancer never gets an address; `cloud target was not found` | 3.3 |
| `x509: certificate signed by unknown authority` (worker)            | 4.1   |
| `Node password rejected` / `Kubelet stopped posting node status`    | 4.2   |
| Infra Up fails at `Guard control-plane replacements`                | 5.1 / 5.3 |
| `kubectl top` / HPA broken, APIService `Available=False`            | 6.1   |
| k3s: `… .crt: read-only file system` (looks like a TLS bug)         | 8.1   |
| node `NotReady` in dashboard but `ssh` works fine                    | 8.1 / ADR-0018 |
| many unrelated units failed at once (cloud-init, snapd, grub)        | 8.1   |
| CPs silently shrank back to 4 GB after an Infra Up                   | 8.2   |
