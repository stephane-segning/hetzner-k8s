# AGENTS

This repository is operated as infrastructure code for a Hetzner-hosted k3s cluster.

## Operating Model

- Use GitHub Actions as the primary control surface.
- Treat `.github/workflows/infra-up.yml`, `.github/workflows/infra-down.yml`, and `.github/workflows/infra-destroy.yml` as the supported lifecycle flows.
- Do not commit local `terraform.tfvars` files or generated backups.
- Keep Terraform state remote in Hetzner Object Storage via the S3 backend.

## Infra Ownership

- Terraform owns:
  - network
  - subnets
  - firewalls
  - servers
  - volumes
  - Kubernetes API load balancer on `:6443`
- Kubernetes/Hetzner CCM owns:
  - ingress load balancers created from `Service.type=LoadBalancer`
- Argo CD in the home cluster owns long-lived in-cluster platform and workloads.

## Cluster Shape

- Default topology:
  - 3 `CPX22` control planes
  - 2 `CPX42` workers
- Bootstrap is deterministic:
  - first control plane initializes cluster
  - remaining control planes join as servers
  - workers join as agents

## Change Rules

- Prefer small, explicit changes.
- Keep node roles deterministic.
- Keep Cilium as the cluster CNI unless the user explicitly requests a networking redesign.
- Keep swap disabled and do not re-enable it implicitly.
- Keep K3s `local-storage` disabled; persistent storage should go through Hetzner CSI.
- Do not reintroduce mixed ownership for load balancers.
- Do not add local-only operational paths as the main documented flow.
- If a workflow depends on Terraform state, assume remote backend usage.

## Validation

- Run `make test` after meaningful changes.
- Keep Terraform valid with `terraform init -backend=false` + `terraform validate` for local checks.
- Render validation must not create persistent local artifacts in `terraform/envs/prod/`.

## Security Notes

- Do not commit secrets.
- Direct node API access on `6443` stays disabled by default.
- Human and Argo CD access should use the Terraform-managed API endpoint.
