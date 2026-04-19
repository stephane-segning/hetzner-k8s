# GitHub Actions

This repository is designed to be operated from GitHub Actions.

## Remote State

Terraform uses an S3-compatible backend. Hetzner Object Storage is the intended backend.

The workflows generate backend configuration at runtime and run `terraform init -reconfigure` with it.

## Required GitHub Secrets

Set these repository or environment secrets:

- `HCLOUD_TOKEN`: Hetzner Cloud API token
- `TF_STATE_BUCKET`: Object Storage bucket name for Terraform state, for example `terraform-state`
- `TF_STATE_KEY`: Object key for the production state file, for example `hetzner-k8s/prod.tfstate`
- `TF_STATE_ENDPOINT`: Object Storage endpoint, for example `nbg1.your-objectstorage.com` or `https://nbg1.your-objectstorage.com`
- `TF_STATE_ACCESS_KEY_ID`: Object Storage access key
- `TF_STATE_SECRET_ACCESS_KEY`: Object Storage secret key

Important:

- `TF_STATE_ACCESS_KEY_ID` and `TF_STATE_SECRET_ACCESS_KEY` are Object Storage credentials, not your Hetzner Cloud API token.
- `HCLOUD_TOKEN` is used for the Hetzner Cloud API.
- `TF_STATE_ENDPOINT` must point to the Object Storage endpoint for your bucket region, for example `nbg1.your-objectstorage.com`.
- The workflows will add `https://` automatically if you omit it.

## Recommended GitHub Variables

Set these as repository or environment variables:

- `TF_CLUSTER_NAME`: defaults to `hetzner-k8s`
- `TF_CONTROL_PLANE_SERVER_TYPE`: defaults to `cpx22`
- `TF_WORKER_SERVER_TYPE`: defaults to `cpx42`
- `TF_CONTROL_PLANE_COUNT`: defaults to `3`
- `TF_WORKER_COUNT`: defaults to `2`
- `TF_LOCATION`: defaults to `fsn1`
- `TF_SSH_KEY_IDS`: JSON list string, for example `[
  "my-ssh-key"
]`
- `TF_API_LOAD_BALANCER_TYPE`: defaults to `lb11`
- `TF_API_SERVER_HOSTNAME`: DNS name for the Kubernetes API, for example `k8s.example.com`.
  Do not include `https://`.
- `TF_OIDC_ISSUER_URL`: Keycloak realm issuer URL
- `TF_OIDC_CLIENT_ID`: defaults to `kubernetes`
- `TF_OIDC_USERNAME_CLAIM`: defaults to `preferred_username`
- `TF_OIDC_GROUPS_CLAIM`: defaults to `groups`
- `TF_OIDC_USERNAME_PREFIX`: defaults to `-`
- `TF_OIDC_GROUPS_PREFIX`: defaults to empty string

## Workflows

### Infra Up

File: `.github/workflows/infra-up.yml`

What it does:

1. Checks out the repo
2. Configures remote Terraform state
3. Runs `terraform fmt -check`
4. Runs `terraform validate`
5. Runs `terraform apply -auto-approve`
6. Powers on all Terraform-managed servers
7. Publishes the API endpoint in the workflow summary

What it does not do:

- does not install Cilium, CCM, CSI, or Traefik
- does not register the cluster in Argo CD
- does not make nodes `Ready` by itself, because Cilium is installed afterward

Use this for:

- first-time provisioning
- normal infra changes
- bringing the cluster back after `Infra Down`

### Infra Down

File: `.github/workflows/infra-down.yml`

What it does:

1. Loads remote Terraform state
2. Powers off all Terraform-managed servers

What it does not do:

- does not destroy servers
- does not remove the Terraform-managed API load balancer
- does not remove CCM-managed ingress load balancers
- does not remove volumes or networks

Use this for:

- temporary shutdown while preserving state and resources

### Infra Destroy

File: `.github/workflows/infra-destroy.yml`

What it does:

1. Loads remote Terraform state
2. Deletes the known CCM-managed Traefik ingress load balancer (`traefik-ingress`)
3. Runs `terraform destroy -auto-approve`

Use this for:

- full environment teardown

## Notes

- `Infra Down` is operationally different from `Infra Destroy`.
- The API load balancer is Terraform-owned.
- The Traefik ingress load balancer is Kubernetes/CCM-owned and must be cleaned up separately on destroy.
- Node public IPs remain allocated for outbound connectivity, but inbound public access to the VMs is blocked by firewall policy.
- If you add more CCM-managed services of type `LoadBalancer`, extend the destroy workflow so their Hetzner load balancers are deleted before Terraform destroy.
- The workflows provision the cluster foundation. Full platform readiness still requires bootstrap validation and in-cluster platform sync.
