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

# Restore from snapshot
k3s server --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/FILENAME
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
