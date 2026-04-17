# GitHub Actions

This repository is designed to be operated from GitHub Actions.

## Remote State

Terraform uses an S3-compatible backend. Hetzner Object Storage is the intended backend.

The workflows generate backend configuration at runtime and run `terraform init -reconfigure` with it.

## Required GitHub Secrets

Set these repository or environment secrets:

- `HCLOUD_TOKEN`: Hetzner Cloud API token
- `TF_STATE_BUCKET`: Object Storage bucket name for Terraform state
- `TF_STATE_KEY`: Object key for the production state file
- `TF_STATE_ENDPOINT`: Object Storage endpoint, for example `https://nbg1.your-objectstorage.com`
- `TF_STATE_ACCESS_KEY_ID`: Object Storage access key
- `TF_STATE_SECRET_ACCESS_KEY`: Object Storage secret key

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
- `TF_ALLOWED_SSH_IPS`: JSON list string, for example `[
  "203.0.113.10/32"
]`
- `TF_ALLOWED_API_IPS`: JSON list string, usually `[]` when using the dedicated API load balancer
- `TF_API_LOAD_BALANCER_TYPE`: defaults to `lb11`

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
- If you add more CCM-managed services of type `LoadBalancer`, extend the destroy workflow so their Hetzner load balancers are deleted before Terraform destroy.
