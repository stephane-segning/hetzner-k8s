# Testing Runbook

This document is the recommended sequence for first validation of the platform.

## Goal

Prove that:

1. Terraform infrastructure provisions successfully
2. k3s bootstraps successfully
3. Cilium makes nodes become `Ready`
4. Hetzner CCM and CSI function correctly
5. Traefik gets a Hetzner ingress load balancer
6. API access works via the dedicated API load balancer
7. Argo CD can be prepared to manage the remote cluster

## Preflight checklist

Before testing, ensure:

- Hetzner Cloud API token exists
- Hetzner Object Storage bucket exists for remote Terraform state
- GitHub repository secrets and variables are configured
- `api_server_hostname` DNS record is planned and can point to the API LB
- Keycloak realm/client values are decided if you want to test OIDC immediately
- Hetzner DNS zones are delegated if you later want to test `external-dns`

## Test sequence

### 1. Static validation

Run:

```bash
make test
```

Expected:

- Terraform validates
- manifests render
- scripts pass syntax checks

### 2. Provision infrastructure

Trigger:

- `Infra Up`

Expected:

- 3 control planes
- 2 workers
- private network
- firewalls
- API load balancer on `:6443`

### 3. Verify API DNS

After the API LB exists:

1. point `api_server_hostname` DNS to the API LB IP
2. confirm DNS resolves correctly
3. confirm the configured hostname matches the intended access name

### 4. Bootstrap k3s

Use the supported break-glass/private path and run:

```bash
make bootstrap
```

Expected:

- nodes register with the API
- nodes may still be `NotReady` until Cilium is installed

### 4a. Publish bootstrap kubeconfig for Platform Up

If you want to use GitHub Actions for the post-bootstrap platform layer, base64-encode the bootstrap kubeconfig and store it in the GitHub secret:

- `REMOTE_CLUSTER_KUBECONFIG_B64`

### 5. Install Base Platform

Run:

```bash
# either locally
make platform-install

# or via GitHub Actions
Platform Up
```

This step installs Cilium first and then continues with the rest of the base platform.

CCM and CSI are installed from Hetzner's official Helm charts.

### 6. Validate Cilium

Expected outcome:

- Cilium pods running in `kube-system`
- nodes transition to `Ready`

Checks:

```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system -l k8s-app=cilium
```

### 7. Validate CCM and CSI

Expected outcome:

- node provider integration becomes healthy
- CSI controller and node pods run successfully

Checks:

```bash
kubectl get pods -n kube-system
kubectl get storageclass
```

### 8. Validate Traefik

Expected outcome:

- Traefik gets a `Service.type=LoadBalancer`
- Hetzner CCM provisions the ingress load balancer

Checks:

```bash
kubectl get svc -n traefik
kubectl get pods -n traefik
```

### 9. Validate storage

Expected outcome:

- default `hcloud-volumes` storage class exists
- PVC provisioning works for RWO workloads

Suggested test:

- create a small PVC and pod using `hcloud-volumes`

### 10. Validate access model

Automation:

- verify `argocd-manager-token` exists
- capture token and CA for Argo CD registration

Humans:

- if OIDC is enabled, verify Keycloak login produces a token accepted by the API
- verify OIDC group RBAC maps correctly

### 11. Validate ingress path

Deploy a simple app behind Traefik and verify:

- LB is reachable
- Ingress routing works
- DNS can be added manually first

## Pass criteria

The cluster is ready for deeper testing when all of these are true:

- all nodes are `Ready`
- Cilium is healthy
- CCM is healthy
- CSI is healthy
- Traefik has an external LB
- API is reachable through the dedicated API hostname
- Argo CD token and CA can be extracted successfully

## Deferred tests

These can be tested later:

- OIDC human login if Keycloak is not ready yet
- `external-dns`
- cert-manager DNS01 with Hetzner DNS
- Longhorn on worker-only volumes
