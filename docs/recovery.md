# Recovery Guide

This guide covers common recovery scenarios for the Hetzner Kubernetes cluster.

For the **why** behind the choices below, see the ADRs:
[0002 — Restore from S3 via Infra Up](adr/0002-restore-etcd-from-s3-via-infra-up.md),
[0003 — Pre-decompress snapshot](adr/0003-pre-decompress-snapshot-before-cluster-reset.md),
[0004 — Sentinel + SKIP_ENABLE](adr/0004-idempotent-restore-skip-enable-sentinel.md),
[0005 — Private NIC bring-up](adr/0005-bring-up-private-nic-in-cloud-init.md),
[0006 — Worker force-replace](adr/0006-force-replace-workers-on-restore.md),
[0007 — Gate CP `-replace` on API reachability](adr/0007-gate-cp-replace-on-api-reachability.md),
[0008 — `/livez` self-validation](adr/0008-self-validate-infra-up-via-livez-gate.md),
[0009 — `mc` for S3 download](adr/0009-mc-for-inline-s3-download-during-restore.md),
[0010 — `etcd-s3=false` override](adr/0010-etcd-s3-false-on-cluster-reset.md),
[0011 — `--node-ip` on cluster-reset](adr/0011-node-ip-on-cluster-reset.md).
For the long-form story of how those decisions came about, see the
[May 2026 cluster-restore lessons-learned](lessons-learned/2026-05-cluster-restore.md).

## Full Cluster Rebuild

If the entire cluster needs to be rebuilt:

```bash
# 1. Trigger Infra Destroy in GitHub Actions
# 2. Trigger Infra Up in GitHub Actions
# 3. Re-run bootstrap validation through the documented break-glass path if needed
# 4. Re-sync platform components from home-cluster Argo CD
```

## Control-Plane Loss with S3 Backups (GH Actions Only)

Use this when all control-plane servers are gone but workers, the API load
balancer, the private network, the firewall, and remote Terraform state are
still intact, and you have valid S3 etcd snapshots. The flow is end-to-end
GH-Actions-driven: it does not require direct SSH to the nodes.

The bootstrap control-plane (`control-plane-01`) will install k3s without
starting it, run `k3s server --cluster-reset --cluster-reset-restore-path=…`
against your S3 snapshot inline (the in-cluster S3 Secret is not available
during restore — it lives in the etcd you are restoring), then start k3s
normally. The other control-plane nodes and workers join the restored cluster
using the unchanged `random_password.k3s_token` from remote Terraform state.

### Prerequisites

- Remote Terraform state is intact (the `random_password.k3s_token` and the
  network/firewall/LB resources must still be in state).
- Worker servers are still running, or are also being recreated by the same
  Infra Up run.
- GH Action secrets are populated: `ETCD_S3_ACCESS_KEY_ID`,
  `ETCD_S3_SECRET_ACCESS_KEY`, `ETCD_S3_BUCKET`, `ETCD_S3_ENDPOINT`, and
  optionally `ETCD_S3_REGION`, `ETCD_S3_FOLDER`, `ETCD_S3_BUCKET_LOOKUP_TYPE`.
- You know which snapshot to restore (the basename inside the S3 folder, not
  an `s3://...` URL). Scheduled snapshots are named
  `etcd-snapshot-<cluster>-<cp-node>-<unix>.zip`, e.g.
  `etcd-snapshot-ssegning-hetzner-k3s-cp-1-1779775201.zip`. Any CP's snapshot
  is fine — etcd snapshots are full, not per-node.

### Procedure

1. Pick the snapshot. The S3 path follows the Platform Up secret layout,
   typically `s3://<ETCD_S3_BUCKET>/<ETCD_S3_FOLDER>/<filename>`. Default
   folder is `<cluster_name>/etcd`.
2. Trigger **Infra Up** in GH Actions with:
    - `restore_from_s3 = true`
    - `restore_snapshot_name = <filename>`
    - `allow_control_plane_replacement = true` only if Terraform plans deletes
      against existing control-plane resources still in state. A create-only
      plan (state already has the CPs removed) does not require this.

   The workflow's pre-flight step refuses to plan if any required ETCD_S3_*
   secret or snapshot name is missing, so the cluster will not boot into a
   broken half-restored state.
3. The workflow's `Terraform plan` step probes the API LB and decides what
   to `-replace`:
    - **First restore (API not reachable)**: `-replace` every non-bootstrap
      control plane and every worker. The CPs must boot fresh (empty
      `/var/lib/rancher/k3s/server/db/`) and join as new etcd members of the
      restored cluster; the workers must drop any CA hash they pinned from a
      prior cluster era.
    - **Re-run against an already-restored cluster (API reachable)**: only
      `-replace` the workers, leave the CPs intact. The sentinel on cp-1
      skips the cluster-reset path, so a second restore-mode Infra Up would
      otherwise destroy cp-2 + cp-3 simultaneously and break etcd quorum
      (1 of 3 voters with no path back to a majority for adding new
      members). Gating on API reachability prevents that trap.

   Failure modes the gate protects against:
    - **Pinned worker CA** (`tls: failed to verify certificate: x509:
     certificate signed by unknown authority`). Workers that joined an
      empty cluster created by a prior failed restore have the wrong CA
      fingerprint cached. Fresh worker VMs bootstrap k3s-agent against the
      current API LB CA and join cleanly.
    - **Etcd quorum loss on re-run**. Without the gate, every restore-mode
      re-run would tear down cp-2 + cp-3 in parallel, leaving cp-1 unable
      to write to etcd until the new members joined — which they couldn't,
      because adding a member is itself a write requiring quorum. Recovery
      from that state requires running `k3s server --cluster-reset` (no
      restore path) on cp-1 manually.
4. `control-plane-01` cloud-init:
    - installs k3s with `INSTALL_K3S_SKIP_START=true` **and**
      `INSTALL_K3S_SKIP_ENABLE=true` so a partial failure cannot be
      "rescued" by systemd auto-starting an empty k3s on the next boot.
    - downloads the snapshot from S3 with `mc` (a single static binary).
    - pre-decompresses the snapshot via `unzip` and passes the absolute
      path of the **uncompressed** file to `--cluster-reset-restore-path`.
      This sidesteps a k3s 1.35.x bug in
      [`pkg/etcd/snapshot.go::decompressSnapshot`](https://github.com/k3s-io/k3s/blob/master/pkg/etcd/snapshot.go)
      where `filepath.Join(snapshotsDir, restorePath)` doubles the prefix
      for absolute `.zip` paths. The non-`.zip` branch of `Restore` uses
      the path verbatim.
    - on success: writes `/var/lib/rancher/k3s/.recovery-restored` as an
      idempotency sentinel (subsequent cloud-init runs skip the restore),
      then `systemctl enable k3s && systemctl start k3s`.
5. `control-plane-02` and `control-plane-03` cloud-init wait on
   `https://<bootstrap-private-ip>:6443/healthz` then join as additional
   servers. Workers reconnect with the unchanged token from remote state.
6. Trigger **Platform Up** in GH Actions to reconcile Cilium, Hetzner CCM/CSI,
   Traefik, and to re-apply the `k3s-etcd-snapshot-s3-config` Secret in
   `kube-system` so that future scheduled snapshots resume against S3.
7. Trigger **Verify Etcd Backups** in GH Actions to confirm a recent S3
   snapshot is present. The just-restored snapshot itself counts; a fresh
   snapshot will land at the next `etcd_snapshot_schedule_cron` tick.
8. For the next Infra Up run, leave `restore_from_s3 = false` (the default).
   Subsequent runs will not touch the control planes because their user_data
   is byte-identical between restore and non-restore modes; the `-replace`
   flags above only fire when `restore_from_s3 = true`.

### What you lose

- Anything created in the cluster after the snapshot timestamp (namespaces,
  CRDs, CNPG WAL beyond the snapshot, application state without an external
  store, etc.). Re-sync from Argo CD will recreate platform manifests.
- Pod CIDR / Cilium identity allocations may rotate; expect a brief reshuffle
  while Cilium reconverges on the restored nodes.

### Security note

When `restore_from_s3 = true`, the S3 credentials are templated into the
control-plane `user_data`. This is the same trust boundary as `HCLOUD_TOKEN`,
which is already in `user_data`. After recovery, rotate the S3 credentials if
your threat model requires it, and re-run Platform Up to update the
`k3s-etcd-snapshot-s3-config` Secret.

## Control-Plane Split-Brain

**Symptom:** consecutive `kubectl get nodes` (through the API LB) return
**different node sets** — e.g. one call shows only `cp-1`, the next shows
`cp-2`/`cp-3` + workers but not `cp-1`. `/readyz` flaps `ok` ↔ `apiserver not
ready`. This means a control plane (almost always the `--cluster-init` bootstrap
node, `cp-1`/`10.0.0.10`) is running a **divergent etcd cluster** and the API LB
is serving it alongside the real one. See
`docs/lessons-learned/2026-06-09-cp1-split-brain.md` and ADR-0017.

> Caused by a rebuilt cluster-init node re-running `--cluster-init` (founds a new
> single-node etcd) instead of joining. ADR-0017's bootstrap guard prevents this
> going forward; this runbook recovers a cluster already in the state.

### 1. Identify the divergent node

External IPs in `kubectl get nodes -o wide` may be stale (CCM mis-report) — trust
SSH `hostname`. The laptop has **no route** to `10.0.0.0/24`; reach a node's
private IP by hopping through a public IP: `ssh -J root@<public-cp> root@10.0.0.x`.

```sh
# A node whose OWN apiserver sees only itself is the divergent one:
ssh -J root@<public-cp> root@10.0.0.10 'k3s kubectl get nodes --no-headers | wc -l'
# 1  -> divergent (running its own cluster)   |   N -> part of the real cluster
```

### 2. Stop the split-brain (immediate)

Stop + disable k3s on the divergent node. Its `:6443` closes and the LB ejects
it within one health-check interval; the API goes consistent again. The real
cluster (the other CPs) is untouched.

```sh
ssh -J root@<public-cp> root@10.0.0.10 'systemctl stop k3s && systemctl disable k3s'
# verify: repeated `kubectl get nodes` are now identical; `kubectl get --raw=/readyz` == ok
```

### 3. Rejoin the node to the real cluster

Park its divergent etcd db and switch it from init to **join** mode. The cluster
token already matches across CPs (`/var/lib/rancher/k3s/server/token`).

SSH **into** the divergent node first — these commands run **on the node**, not
on the laptop (the `ssh -J` line is interactive; don't paste it together with the
block below or the rest leaks to your local shell):

```sh
ssh -J root@<public-cp> root@10.0.0.10
```

```sh
# --- on 10.0.0.10 ---
systemctl stop k3s 2>/dev/null
mv /var/lib/rancher/k3s/server/db /var/lib/rancher/k3s/server/db.splitbrain-bak-$(date +%s)
# swap init -> join (point at any surviving CP; here 10.0.0.11):
sed -i 's|--cluster-init|--server https://10.0.0.11:6443|g' /etc/systemd/system/k3s.service
grep -c -- '--cluster-init' /etc/systemd/system/k3s.service   # MUST print 0 BEFORE starting
systemctl daemon-reload && systemctl enable --now k3s
```

The node joins the surviving etcd as a **learner → promoted** member. Verify:
its own `k3s kubectl get nodes` now lists **all** nodes; etcd quorum is back to 3.

> ⚠️ **Both steps are mandatory, in order.** Wiping the db **without** the
> `--cluster-init`→`--server` swap is exactly what *creates* the split-brain (the
> node re-inits). The `grep -c -- '--cluster-init' == 0` check gates the start.
>
> ⚠️ Do **not** automate this. Run it live, step by step — an unattended run is
> what caused the 2026-06-09 incident.

## Node Recovery

### Node `NotReady` after reboot / replace / restore — node-password rejected

**Symptom.** One or more nodes are `NotReady` with
`Kubelet stopped posting node status`. On the node, `journalctl -u k3s-agent`
(workers) or `journalctl -u k3s` (servers) shows:

```
Node password rejected, duplicate hostname or contents of
'/etc/rancher/node/password' may not match server node-passwd entry,
try enabling a unique node name with the --with-node-id flag
```

**Cause.** k3s stores `hash(node-password)` in a `kube-system` Secret
`<nodename>.node-password.k3s` and rejects a join whose presented password
doesn't match. The on-disk `/etc/rancher/node/password` and the stored
Secret drifted apart — typically because the node was re-provisioned
(fresh disk → new password), or an etcd restore re-introduced an
older-era Secret. See [ADR-0012](adr/0012-deterministic-node-password.md).

**Permanent fix** (already in the codebase as of ADR-0012): cloud-init
pre-seeds a deterministic `/etc/rancher/node/password` derived from the
cluster token + hostname, so every (re)provision of a node name presents
the same password and matches the stored Secret. New nodes are correct
automatically.

**Break-glass remediation** (for nodes provisioned before ADR-0012, or any
residual mismatch) — delete the stale Secret(s) and let the agent
re-register. Non-destructive; node-password is only a join-time
anti-spoofing token, not workload data:

```bash
# From any control plane (or with a working kubeconfig).
# Delete the Secret for EACH affected node — this can hit control planes
# (k3s server) as well as workers (k3s-agent), so include whichever nodes
# show "Node password rejected". Listing all six is safe; only mismatched
# nodes recreate their Secret.
for n in cp-1 cp-2 cp-3 worker-1 worker-2 worker-3; do
  kubectl -n kube-system delete secret "ssegning-hetzner-k3s-$n.node-password.k3s" --ignore-not-found
done
# The k3s / k3s-agent services are already in a ~7s retry loop; nodes go
# Ready within ~30s.
kubectl get nodes -w
```

Confirm the node's on-disk password is present first
(`ssh root@<node> 'test -s /etc/rancher/node/password && echo ok'`); if it
is missing, the node will mint a fresh one on next start and the deleted
Secret will be recreated from it.

### Recover a wedged / `NotReady` node (GH Actions — supported path)

When a single node dies but the cluster as a whole is healthy — e.g. a
worker host hard-hangs (answers ping/TCP but `sshd` and kubelet are stuck;
kubelet stopped posting status) — recover it through **Infra Up** rather
than a console reboot or a local `terraform apply`. Workers carry no etcd
vote, so destroying and recreating one is safe; cloud-init re-runs and the
node rejoins fresh against the same CA (its node-password is stable per
ADR-0012).

1. Identify the dead node from `kubectl get nodes` (e.g. `…-worker-3`
   `NotReady`).
2. Run **Infra Up** with:
   - `replace_nodes` = the node key, e.g. `worker-03`. Both the padded
     state-key form (`worker-03`) and the unpadded kubectl-name form
     (`worker-3`) are accepted; multiple keys may be comma/space-separated.
   - Leave `restore_from_s3=false`.
   - For a **control-plane** key you must *also* set
     `allow_control_plane_replacement=true` — and only as deliberate
     recovery work (it is gated for good reason; see the control-plane
     section above and ADR-0007).
3. The plan force-replaces only the named node(s); every other node is a
   no-op. The post-apply readiness gate confirms the cluster is healthy
   before the run reports success.

Invalid or not-in-state keys are reported in the run summary and skipped,
so a typo cannot silently replace the wrong node.

### Single Node Failure (break-glass, local Terraform)

If a single node fails and you cannot use Infra Up:

1. **Check Hetzner Console**: Verify the server status
2. **Rebuild via Terraform**:
   ```bash
   # Break-glass local Terraform only.
   # Remove failed node from state (if needed)
   terraform -chdir=terraform/envs/prod state rm 'module.servers.hcloud_server.main[INDEX]'
   
   # Re-apply to recreate
   make apply
   ```

3. **Re-join to cluster**: The node will auto-join via cloud-init

### Node Re-provisioning

To completely reprovision a specific node:

```bash
# Choose the Terraform node key, for example:
# control-plane-01
# control-plane-02
# worker-01
# worker-02
NODE_KEY="worker-01"

# Destroy specific server
terraform -chdir=terraform/envs/prod apply \
  -replace="module.servers.hcloud_server.main[\"${NODE_KEY}\"]"
  
# Wait for provisioning
# Node will auto-join cluster
```

Do not use Terraform `-replace` as a routine control-plane maintenance path in this repository. The current bootstrap
contract makes control-plane replacement recovery-grade work, especially for the `--cluster-init` node.

### Verify Etcd Backups

Use this before and after meaningful infrastructure changes:

```bash
kubectl get etcdsnapshotfile
kubectl get etcdsnapshotfile -o json | jq -r '.items[] | select((.spec.location // "") | startswith("s3://")) | .spec.location'
kubectl -n kube-system get secret k3s-etcd-snapshot-s3-config
```

Supported workflow path:

1. Run `Platform Up` if the etcd S3 Secret may have changed.
2. Run `Verify Etcd Backups` in GitHub Actions.
3. Confirm that recent `s3://...` snapshots are present before any disruptive work.

If a control-plane node must be rebuilt, treat it as deliberate recovery or cluster migration work backed by verified
snapshots, not as a normal day-two operation.

## k3s Recovery

### k3s Server Failure

If k3s fails on the server node:

```bash
# SSH to bootstrap control-plane
ssh root@$(terraform -chdir=terraform/envs/prod output -raw first_control_plane_ip)

# Check status
systemctl status k3s
journalctl -u k3s -n 50

# Reset k3s
/usr/local/bin/k3s-uninstall.sh

# Reinstall
TOKEN=$(terraform -chdir=terraform/envs/prod output -raw k3s_token)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=server sh -s - \
  --token=$TOKEN \
  --cluster-init \
  --node-ip=<private-ip> \
  --advertise-address=<private-ip> \
  --disable traefik \
  --disable servicelb \
  --disable local-storage \
  --disable-network-policy \
  --flannel-backend=none
```

### Etcd Issues

If embedded etcd has issues:

```bash
# Check etcd status
k3s etcd-snapshot list
```

Back up the server token as part of the same recovery set:

```bash
cp /var/lib/rancher/k3s/server/token /root/k3s-server-token.backup
```

To restore a multi-server control plane from a local snapshot:

```bash
# Stop k3s on all control-plane nodes first.
systemctl stop k3s

# On the restore source node only:
k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/FILENAME

systemctl start k3s

# On the other control-plane nodes before restarting k3s:
rm -rf /var/lib/rancher/k3s/server/db/
systemctl start k3s
```

To restore from S3, pass the snapshot filename and the S3 settings explicitly because the Kubernetes Secret is not
available during restore:

```bash
k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=FILENAME \
  --token="$(cat /var/lib/rancher/k3s/server/token)" \
  --etcd-s3 \
  --etcd-s3-bucket="$ETCD_S3_BUCKET" \
  --etcd-s3-endpoint="$ETCD_S3_ENDPOINT" \
  --etcd-s3-region="${ETCD_S3_REGION:-eu-central}" \
  --etcd-s3-access-key="$ETCD_S3_ACCESS_KEY_ID" \
  --etcd-s3-secret-key="$ETCD_S3_SECRET_ACCESS_KEY" \
  --etcd-s3-folder="${ETCD_S3_FOLDER:-hetzner-k8s/etcd}"
```

## Platform Component Recovery

### Hetzner CCM Not Working

```bash
# Check pod status
kubectl get pods -n kube-system -l app=hcloud-cloud-controller-manager

# Check logs
kubectl logs -n kube-system -l app=hcloud-cloud-controller-manager

# Verify secret
kubectl get secret hcloud -n kube-system -o yaml

# Recreate if needed
kubectl delete secret hcloud -n kube-system
kubectl create secret generic hcloud -n kube-system \
  --from-literal=token=$HCLOUD_TOKEN \
  --from-literal=network=$HCLOUD_NETWORK
kubectl rollout restart deployment hcloud-cloud-controller-manager -n kube-system
```

### Hetzner CSI Not Working

```bash
# Check CSI pods
kubectl get pods -n kube-system -l app=hcloud-csi-controller
kubectl get pods -n kube-system -l app=hcloud-csi-node

# Check secret
kubectl get secret hcloud-csi -n kube-system

# Restart CSI
kubectl rollout restart deployment hcloud-csi-controller -n kube-system
kubectl rollout restart daemonset hcloud-csi-node -n kube-system
```

### Traefik Issues

```bash
# Check Traefik
kubectl get pods -n traefik
kubectl logs -n traefik -l app.kubernetes.io/name=traefik

# Check service
kubectl get svc -n traefik traefik

# Check load balancer annotations
kubectl get svc -n traefik traefik -o yaml | grep -A10 annotations

# Restart Traefik
kubectl rollout restart deployment traefik -n traefik
```

If the Hetzner ingress load balancer exists but cannot reach Traefik, verify the nodes are advertising private addresses
to Kubernetes.

### Cilium Issues

```bash
# Check Cilium state
kubectl get pods -n kube-system -l k8s-app=cilium
kubectl get pods -n kube-system -l name=cilium-operator

# Restart Cilium components
kubectl rollout restart daemonset cilium -n kube-system
kubectl rollout restart deployment cilium-operator -n kube-system
```

If K3s must be fully uninstalled from a node, remove the Cilium interfaces first to avoid losing host connectivity:

```bash
ip link delete cilium_host || true
ip link delete cilium_net || true
ip link delete cilium_vxlan || true
iptables-save | grep -iv cilium | iptables-restore
ip6tables-save | grep -iv cilium | ip6tables-restore
```

## Data Recovery

### Volume Recovery

For persistent volumes:

1. **Check volume status**:
   ```bash
   kubectl get pv
   kubectl get pvc -A
   ```

2. **Volume stuck**:
   ```bash
   # Force delete (caution!)
   kubectl patch pvc PVC_NAME -p '{"metadata":{"finalizers":null}}'
   ```

3. **Recover from Hetzner**:
    - Volumes persist in Hetzner Cloud Console
    - Can be manually attached to nodes if needed

### Database Recovery

For CNPG (CloudNativePG) databases:

1. **Check cluster status**:
   ```bash
   kubectl get cluster -n data
   kubectl get pods -n data -l postgresql.cnpg.io/cluster=CLUSTER_NAME
   ```

2. **Restore from backup** (if configured):
   ```bash
   kubectl cnpg restore CLUSTER_NAME -n data --backup-name BACKUP_NAME
   ```

## Network Recovery

### Private Network Issues

1. **Check network attachment**:
   ```bash
   # On each node
   ip addr show eth1
   ```

2. **Verify firewall rules** in Hetzner Console

3. **Check NetworkPolicies**:
   ```bash
   kubectl get networkpolicy -A
   ```

### Load Balancer Issues

1. **Check LB in Hetzner Console**
2. **Verify CCM is running**
3. **Check service annotations**:
   ```bash
   kubectl get svc -n traefik traefik -o yaml
   ```

## State Recovery

### Terraform State Issues

```bash
# List state
terraform -chdir=terraform/envs/prod state list

# Import existing resource
terraform -chdir=terraform/envs/prod import \
  hcloud_server.main[0] SERVER_ID

# Refresh state
terraform -chdir=terraform/envs/prod refresh
```

### Lost kubeconfig

```bash
# Retrieve from first node
make get-kubeconfig

# Or manually
ssh root@$(terraform -chdir=terraform/envs/prod output -raw first_control_plane_ip) \
  'cat /etc/rancher/k3s/k3s.yaml' | \
  sed 's/127.0.0.1/'$(terraform -chdir=terraform/envs/prod output -raw api_server_hostname || terraform -chdir=terraform/envs/prod output -raw api_load_balancer_ip)'/g' \
  > kubeconfig
```

## Emergency Procedures

### Complete Disaster

1. **Backup critical data** (if accessible)
2. **Destroy cluster**:
   ```bash
   # Preferred: use Infra Destroy in GitHub Actions
   ```
3. **Rebuild from scratch**
4. **Restore from backups** (if available)

### Lockout Recovery

If locked out of all nodes:

1. **Use Hetzner Console**:
    - Access via VNC console
    - Reset root password if needed

2. **Reset firewall**:
    - Temporarily allow all SSH in Hetzner Console
    - Fix firewall rules via Terraform

## Prevention

### Recommended Practices

1. **Regular backups**:
    - etcd snapshots
    - Database backups
    - Volume snapshots

2. **Monitoring**:
    - Node health alerts
    - Pod restart alerts
    - Resource usage alerts

3. **Documentation**:
    - Keep record of changes
    - Document custom configurations
    - Maintain runbooks

4. **Testing**:
    - Periodic recovery drills
    - Backup restoration tests
    - Failover testing
