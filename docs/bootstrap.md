# Bootstrap Guide

This guide covers the detailed bootstrap process for the Hetzner Kubernetes cluster.

## Prerequisites

- Terraform >= 1.6 installed
- Hetzner Cloud account with API token
- SSH key pair (add public key to Hetzner Cloud Console)
- kubectl installed
- helm installed (optional, for local testing)

## Step 1: Configure Variables

1. Copy the example variables file:

```bash
cp terraform/envs/prod/terraform.tfvars.example terraform/envs/prod/terraform.tfvars
```

2. Edit `terraform.tfvars` with your values:

```hcl
hcloud_token = "YOUR_HCLOUD_API_TOKEN"  # Required
ssh_key_ids = ["your-ssh-key-name"]     # Your SSH key name in Hetzner
allowed_ssh_ips = ["YOUR_IP/32"]        # Your IP for SSH access
```

## Step 2: Initialize Terraform

```bash
make init
```

This downloads the Hetzner provider and initializes the working directory.

## Step 3: Plan Infrastructure

```bash
make plan
```

Review the plan output. You should see:
- 1 private network
- 1 firewall
- 3 `CPX22` control-plane servers by default
- 2 `CPX42` worker servers by default

## Step 4: Apply Infrastructure

```bash
make apply
```

This creates all resources in Hetzner Cloud. Takes ~2-5 minutes.

## Step 5: Bootstrap k3s Cluster

After infrastructure is ready, bootstrap the cluster:

```bash
make bootstrap
```

This script will:
1. Wait for SSH access on all nodes
2. Wait for cloud-init to disable swap and bootstrap k3s on the first control-plane
3. Wait for the API server to be ready
4. Wait for the remaining control-plane and worker nodes to join
5. Verify the cluster
6. Retrieve the kubeconfig

At this point the nodes are expected to be registered but may not be `Ready` until Cilium is installed.

**Expected output:**
```
==> Starting k3s cluster bootstrap
==> Checking prerequisites...
==> Getting Terraform outputs...
==> Waiting for SSH on nodes...
==> Waiting for k3s API...
==> Verifying cluster...
NAME        STATUS   ROLES                       AGE   VERSION
hetzner-k8s-cp-1   NotReady   control-plane,etcd,master   1m    v1.xx.x+k3s.x
hetzner-k8s-cp-2   NotReady   control-plane,etcd,master   30s   v1.xx.x+k3s.x
hetzner-k8s-worker-1 NotReady <none>            30s   v1.xx.x+k3s.x
==> Retrieving kubeconfig...
==> Bootstrap complete!
```

## Step 6: Install Cilium

Install Cilium before expecting node readiness:

```bash
helm repo add cilium https://helm.cilium.io
helm repo update
helm install cilium cilium/cilium \
  --namespace kube-system \
  --values platform/helm-values/cilium-values.yaml
```

## Step 7: Verify Cluster

```bash
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes -o wide
kubectl get pods -A
```

## Step 8: Apply Platform Components

Install the Hetzner CCM and CSI:

```bash
# Render secret manifests from Terraform outputs
terraform -chdir=terraform/envs/prod output -raw hcloud_ccm_secret_manifest | kubectl apply -f -
terraform -chdir=terraform/envs/prod output -raw hcloud_csi_secret_manifest | kubectl apply -f -

# Apply platform manifests
kubectl apply -f platform/base/namespaces.yaml
kubectl apply -f platform/base/networkpolicy-default-deny.yaml
kubectl apply -f platform/base/networkpolicy-dns.yaml
kubectl apply -f platform/base/networkpolicy-data.yaml
kubectl apply -f platform/base/networkpolicy-ingress.yaml
kubectl apply -f platform/base/hcloud-ccm.yaml
kubectl apply -f platform/base/hcloud-csi.yaml
```

## Step 9: Install Traefik with Helm

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm install traefik traefik/traefik \
  --namespace traefik \
  --create-namespace \
  --values platform/helm-values/traefik-values.yaml
```

## Step 10: Verify Platform

```bash
# Check all pods are running
kubectl get pods -A

# Check Traefik service has LoadBalancer IP
kubectl get svc -n traefik

# Check nodes have provider IDs
kubectl get nodes -o wide
```

## Manual Bootstrap (Alternative)

If the automated bootstrap fails, you can manually bootstrap:

### Initialize Bootstrap Control-Plane

```bash
# SSH to first node
ssh root@$(terraform -chdir=terraform/envs/prod output -raw first_control_plane_ip)

# Install k3s server
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=server sh -s - \
  --token=$(terraform -chdir=terraform/envs/prod output -raw k3s_token) \
  --cluster-init \
  --disable traefik \
  --disable servicelb \
  --disable local-storage \
  --disable-network-policy \
  --flannel-backend=none \
  --write-kubeconfig-mode "0644"
```

### Join Additional Nodes

```bash
# Get bootstrap control-plane private IP
SERVER_PRIVATE_IP=$(terraform -chdir=terraform/envs/prod output -raw first_control_plane_private_ip)
TOKEN=$(terraform -chdir=terraform/envs/prod output -raw k3s_token)

# Additional control-plane nodes join with INSTALL_K3S_EXEC=server
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=server sh -s - \
  --server=https://$SERVER_PRIVATE_IP:6443 \
  --token=$TOKEN \
  --disable traefik \
  --disable servicelb \
  --disable local-storage \
  --disable-network-policy \
  --flannel-backend=none \
  --write-kubeconfig-mode "0644"

# Worker nodes join with INSTALL_K3S_EXEC=agent
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=agent sh -s - \
  --server=https://$SERVER_PRIVATE_IP:6443 \
  --token=$TOKEN
```

## Troubleshooting

### SSH Connection Refused

- Wait longer for cloud-init to complete (~5 min)
- Check firewall allows your IP
- Verify SSH key is added to Hetzner

### k3s Server Not Ready

- Check logs: `journalctl -u k3s -f`
- Verify node has sufficient resources
- Check network connectivity

### Nodes Stay NotReady

- Install Cilium first; k3s is started without Flannel
- Check Cilium pods: `kubectl get pods -n kube-system -l k8s-app=cilium`
- Verify swap is disabled: `swapon --show`

### Agent Can't Join

- Verify server API is accessible
- Check token matches
- Verify private network connectivity

### Load Balancer Not Created

- Wait for CCM to initialize
- Check CCM logs: `kubectl logs -n kube-system -l app=hcloud-cloud-controller-manager`
- Verify hcloud secret exists

## Next Steps

After bootstrap is complete:

1. Configure Argo CD in home cluster to manage this cluster
2. Apply Argo CD Application manifests
3. Deploy workloads via GitOps
