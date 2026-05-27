# Recovery Guide

This guide covers common recovery scenarios for the Hetzner Kubernetes cluster.

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
3. The workflow's `Terraform plan` step automatically passes
   `-replace=module.servers.hcloud_server.main["control-plane-NN"]` for every
   non-bootstrap control plane when `restore_from_s3=true`. This is required:
   etcd is a single replicated store, so only `control-plane-01` runs
   `--cluster-reset --cluster-reset-restore-path`. The other CPs must boot
   fresh (empty `/var/lib/rancher/k3s/server/db/`) and join as new etcd
   members, otherwise their stale member IDs would prevent quorum.
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

## Node Recovery

### Single Node Failure

If a single node fails:

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

Do not use Terraform `-replace` as a routine control-plane maintenance path in this repository. The current bootstrap contract makes control-plane replacement recovery-grade work, especially for the `--cluster-init` node.

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

If a control-plane node must be rebuilt, treat it as deliberate recovery or cluster migration work backed by verified snapshots, not as a normal day-two operation.

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

To restore from S3, pass the snapshot filename and the S3 settings explicitly because the Kubernetes Secret is not available during restore:

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

If the Hetzner ingress load balancer exists but cannot reach Traefik, verify the nodes are advertising private addresses to Kubernetes.

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
