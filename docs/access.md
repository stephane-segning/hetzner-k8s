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

1. apply `platform/base/cluster-access.yaml`
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
