# Access

This document explains how machines and humans should access the cluster.

## Principles

- do not distribute the bootstrap admin kubeconfig as the normal access mechanism
- use the API load balancer as the stable Kubernetes API endpoint
- use ServiceAccounts for automation
- use OIDC for humans

## API endpoint

The supported API entrypoint is the Terraform output:

- `api_server_endpoint`

Recommended configuration:

1. create a DNS name such as `k8s.example.com`
2. point it to the API load balancer IP
3. set `api_server_hostname = "k8s.example.com"`

This matters because the Kubernetes API certificate needs a SAN that matches the load-balancer-facing hostname.

## Automation access

### Argo CD

Argo CD should use a dedicated ServiceAccount token.

Scaffolded resources are in:

- `platform/base/cluster-access.yaml`

Included:

- `ServiceAccount` named `argocd-manager`
- service-account token `Secret`
- `ClusterRoleBinding` to `cluster-admin`

Required data for Argo CD cluster registration:

1. `api_server_endpoint`
2. cluster CA bundle
3. token from `platform/argocd-manager-token`

Suggested process:

1. run `make platform-install` or apply `platform/base/cluster-access.yaml`
2. read the token from the generated secret
3. register the remote cluster in the home Argo CD instance using the endpoint, CA, and token

Example commands:

```bash
API_SERVER_ENDPOINT=$(terraform -chdir=terraform/envs/prod output -raw api_server_endpoint)

ARGOCD_MANAGER_TOKEN=$(kubectl -n platform get secret argocd-manager-token \
  -o jsonpath='{.data.token}' | base64 --decode)

CLUSTER_CA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
```

Use these values in the home Argo CD cluster secret or registration flow.

Example Argo CD cluster secret for the home cluster:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: hetzner-remote-cluster
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
stringData:
  name: hetzner-remote
  server: https://k8s.example.com:6443
  config: |
    {
      "bearerToken": "<ARGOCD_MANAGER_TOKEN>",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "<BASE64_CLUSTER_CA>"
      }
    }
```

Replace:

- `https://k8s.example.com:6443` with `api_server_endpoint`
- `<ARGOCD_MANAGER_TOKEN>` with the decoded `argocd-manager-token`
- `<BASE64_CLUSTER_CA>` with the cluster CA bundle

Apply that secret in the home Argo CD cluster namespace.

## Human access

### OIDC

The Kubernetes API is configured for OIDC through Keycloak when these Terraform vars are set:

- `oidc_issuer_url`
- `oidc_client_id`
- `oidc_username_claim`
- `oidc_groups_claim`
- `oidc_username_prefix`
- `oidc_groups_prefix`

### RBAC examples

The repo includes example group bindings in `platform/base/cluster-access.yaml`:

- `k8s-admins` -> `cluster-admin`
- `k8s-viewers` -> `view`

You can change these group names to match your Keycloak realm design.

### kubectl client pattern

You still need a client config, but it should be an OIDC-based client config, not the static bootstrap admin kubeconfig.

Recommended pattern:

- use a kubectl OIDC exec plugin such as `kubectl oidc-login` / `kubelogin`
- point it at the Keycloak issuer and the API load balancer hostname
- let Keycloak issue and refresh user tokens

This keeps long-lived cluster-admin client certs out of normal use.

Example shape of a human OIDC client config:

```bash
kubectl config set-cluster hetzner-prod \
  --server="https://k8s.example.com:6443" \
  --certificate-authority=/path/to/cluster-ca.pem

kubectl config set-credentials oidc-user \
  --exec-command=kubectl \
  --exec-api-version=client.authentication.k8s.io/v1beta1 \
  --exec-arg=oidc-login \
  --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://keycloak.example.com/realms/platform \
  --exec-arg=--oidc-client-id=kubernetes \
  --exec-arg=--oidc-extra-scope=groups

kubectl config set-context hetzner-prod \
  --cluster=hetzner-prod \
  --user=oidc-user
```

Adjust the issuer URL, hostname, and CA path to your environment.

## Quick test flow

If the cluster is already provisioned and bootstrapped, a practical first test sequence is:

1. Confirm the API hostname resolves to the API load balancer
2. Confirm Cilium is healthy and nodes are `Ready`
3. Apply `platform/base/cluster-access.yaml`
4. Extract the `argocd-manager-token`
5. Build or apply the Argo CD cluster secret in the home cluster
6. Verify the remote cluster appears in Argo CD
7. Test human OIDC login with a Keycloak user in `k8s-admins` or `k8s-viewers`

Useful checks:

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl -n platform get secret argocd-manager-token
kubectl auth can-i get pods --all-namespaces
```

## Authorino

`Authorino` is useful for:

- application/API authorization behind ingress
- protecting workload endpoints exposed by Traefik

`Authorino` is not the mechanism for protecting the Kubernetes API server itself.

For the Kubernetes API, the correct controls are:

- TLS
- Kubernetes OIDC authentication
- Kubernetes RBAC authorization
- optional outer network controls such as VPN/private access in the future

## Break-glass access

Break-glass access is intentionally separate from the normal operator path.

Use one of:

- Hetzner Console / VNC console
- private-network access from a trusted admin environment
- a future jump host or VPN if you decide to add one

Do not plan day-to-day operations around direct VM access.
