# Bootstrap Guide

This guide covers the detailed bootstrap process for the Hetzner Kubernetes cluster.

The supported operating path is GitHub Actions plus the Terraform-managed API load balancer. Direct public access to individual nodes is intentionally disabled.

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
api_server_hostname = "k8s.example.com" # DNS name for the API load balancer
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

Note: `make bootstrap` requires private network access or an equivalent break-glass path to the nodes. It is not part of the normal public operating model.

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

## Step 6: Install Base Platform

Install the post-bootstrap platform layer:

```bash
make platform-install
```

If you are not using local Terraform state, provide the Hetzner inputs explicitly:

```bash
export HCLOUD_TOKEN="<hetzner-cloud-api-token>"
export HCLOUD_NETWORK="<terraform network_id output>"
make platform-install
```

`make platform-install` uses Terraform outputs when they are available locally. Otherwise it uses `HCLOUD_TOKEN` and `HCLOUD_NETWORK` from the environment.

This installs:

- Cilium
- Hetzner CCM via the official Hetzner Helm chart
- Hetzner CSI via the official Hetzner Helm chart
- Traefik
- cluster access scaffolding
- baseline NetworkPolicies

## Step 7: Verify Cluster

```bash
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes -o wide
kubectl get pods -A
```

## Step 7a: Prepare Argo CD Access

After the cluster is reachable through the API load balancer, use the `argocd-manager` ServiceAccount for home-cluster Argo CD registration.

The scaffolded resources live in `platform/base/cluster-access.yaml`.

Argo CD should store:

- API server endpoint from `api_server_endpoint`
- cluster CA data
- bearer token from `platform/argocd-manager-token`

## Step 8: Verify Platform

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

This path assumes private or console-based access to the nodes. Public SSH access is not part of the default design.

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
- Use your private or break-glass node access path
- Verify the SSH key exists in Hetzner Cloud if you rely on direct node access

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
