# Architecture

This document describes the intended architecture of the remote Hetzner cluster and the ownership boundaries around it.

## Goals

- self-managed Kubernetes on Hetzner Cloud
- stable API endpoint for automation and humans
- no public access to individual VMs
- private in-cluster networking
- GitHub Actions as the main infrastructure control surface
- home-cluster Argo CD manages long-lived in-cluster resources

## Topology

Default node layout:

- `3 x CPX22` control planes
- `2 x CPX42` workers

Node roles are deterministic:

- first control plane initializes the cluster
- remaining control planes join as servers
- workers join as agents

## Networking

### Private network

All cluster nodes are attached to a Hetzner private network.

Used for:

- control-plane to worker communication
- Kubernetes API traffic from the dedicated API load balancer to the control planes
- storage traffic
- in-cluster east-west traffic

### Public entry points

There are only two intended public entry points:

1. Terraform-managed Kubernetes API load balancer on `:6443`
2. Kubernetes/CCM-managed ingress load balancer created from the Traefik Service

Direct public access to node `22`, `80`, `443`, and `6443` is blocked by firewall policy.

## Kubernetes stack

### Distribution

- Ubuntu `24.04 LTS`
- `k3s`
- embedded etcd for HA control plane

### Disabled k3s components

The bootstrap intentionally disables these k3s defaults:

- Flannel
- k3s network policy controller
- `servicelb`
- Traefik
- `local-storage`

### Installed platform components

- Cilium
- Hetzner CCM
- Hetzner CSI
- Traefik
- baseline namespaces and NetworkPolicies
- Alloy scaffold
- optional kube-state-metrics scaffold

## Storage model

Default persistent storage path:

- Hetzner CSI
- `ReadWriteOnce`

Worker-only attached volumes:

- extra Terraform-created data volumes are attached only to worker nodes
- this keeps future Longhorn-style data paths off the control plane

## Access model

### Automation

Automation should use:

- API endpoint from `api_server_endpoint`
- cluster CA
- dedicated ServiceAccount token

Argo CD is the primary example.

### Humans

Humans should use:

- Kubernetes OIDC against Keycloak
- RBAC bound to OIDC groups such as `k8s-admins` and `k8s-viewers`

### Break-glass

Break-glass node access is not part of the public operating model.

If you need direct node access for recovery or bootstrap debugging, use one of:

- Hetzner Console / VNC console
- private-network access from a trusted admin environment
- a separately designed jump-host or VPN path

## Ownership model

Terraform owns:

- network
- subnet
- firewalls
- servers
- worker-only extra data volumes
- Kubernetes API load balancer
- cloud-init bootstrap inputs

Kubernetes + Hetzner CCM own:

- ingress load balancers created from Services

Home-cluster Argo CD owns:

- long-lived in-cluster platform components
- workloads
- most day-2 configuration after the base infra/bootstrap layer

## DNS model

Recommended DNS split:

- API endpoint DNS is managed outside the cluster and points to the Terraform-managed API LB
- workload/ingress DNS can later be automated with `external-dns` if you use Hetzner DNS

See `docs/external-dns.md`.
