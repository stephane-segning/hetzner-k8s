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
- `REMOTE_CLUSTER_KUBECONFIG_B64`: base64-encoded bootstrap kubeconfig used only for the initial platform-install workflow
- `ETCD_S3_ACCESS_KEY_ID`: S3 access key for k3s etcd snapshot replication
- `ETCD_S3_SECRET_ACCESS_KEY`: S3 secret key for k3s etcd snapshot replication
- `ETCD_S3_BUCKET`: snapshot bucket if you prefer storing it as a secret
- `ETCD_S3_ENDPOINT`: snapshot endpoint if you prefer storing it as a secret
- `ETCD_S3_REGION`: optional snapshot region if you prefer storing it as a secret
- `ETCD_S3_FOLDER`: optional snapshot prefix if you prefer storing it as a secret
- `ETCD_S3_RETENTION`: optional S3 retention count if you prefer storing it as a secret
- `ETCD_S3_BUCKET_LOOKUP_TYPE`: optional lookup type if you prefer storing it as a secret
- `ETCD_S3_CONFIG_SECRET_NAME`: optional Kubernetes Secret name override if you prefer storing it as a secret

Important:

- `TF_STATE_ACCESS_KEY_ID` and `TF_STATE_SECRET_ACCESS_KEY` are Object Storage credentials, not your Hetzner Cloud API token.
- `HCLOUD_TOKEN` is used for the Hetzner Cloud API.
- `TF_STATE_ENDPOINT` must point to the Object Storage endpoint for your bucket region, for example `nbg1.your-objectstorage.com`.
- The workflows will add `https://` automatically if you omit it.
- Using the same Hetzner Object Storage service for Terraform state and etcd snapshots is supported.
- Keep etcd snapshot backups isolated from Terraform state with a separate bucket when possible, or at minimum a separate prefix and independent retention policy.

### Creating `REMOTE_CLUSTER_KUBECONFIG_B64`

This secret is only needed for the initial `Platform Up` workflow.

From a machine that already has the bootstrap kubeconfig file:

macOS:

```bash
base64 < kubeconfig | tr -d '\n'
```

Linux:

```bash
base64 -w0 kubeconfig
```

Copy the resulting single-line value into the GitHub secret `REMOTE_CLUSTER_KUBECONFIG_B64`.

## Recommended GitHub Variables

Set these as repository or environment variables:

- `TF_CLUSTER_NAME`: defaults to `hetzner-k8s`
- `TF_CONTROL_PLANE_SERVER_TYPE`: defaults to `cpx22`
- `TF_WORKER_SERVER_TYPE`: defaults to `cpx42`
- `TF_CONTROL_PLANE_COUNT`: defaults to `3`
- `TF_WORKER_COUNT`: defaults to `2`
- `TF_LOCATION`: defaults to `nbg1`
- `TF_SSH_KEY_IDS`: JSON list string, for example `[
  "my-ssh-key"
]`
- `TF_API_LOAD_BALANCER_TYPE`: defaults to `lb11`
- `TF_API_SERVER_HOSTNAME`: DNS name for the Kubernetes API, for example `k8s.example.com`.
  Do not include `https://`.
- `TF_ETCD_SNAPSHOT_SCHEDULE_CRON`: defaults to `0 */6 * * *`
- `TF_ETCD_SNAPSHOT_RETENTION`: defaults to `14`
- `TF_ETCD_SNAPSHOT_COMPRESS`: defaults to `true`
- `TF_ETCD_S3_ENABLED`: defaults to `true`
- `TF_ETCD_S3_CONFIG_SECRET_NAME`: defaults to `k3s-etcd-snapshot-s3-config`
- `TF_OIDC_ISSUER_URL`: Keycloak realm issuer URL
- `TF_OIDC_CLIENT_ID`: defaults to `kubernetes`
- `TF_OIDC_USERNAME_CLAIM`: defaults to `preferred_username`
- `TF_OIDC_GROUPS_CLAIM`: defaults to `groups`
- `TF_OIDC_USERNAME_PREFIX`: defaults to `-`
- `TF_OIDC_GROUPS_PREFIX`: defaults to empty string
- `ETCD_S3_BUCKET`: bucket for etcd snapshots
- `ETCD_S3_ENDPOINT`: S3 endpoint for etcd snapshots, for example `nbg1.your-objectstorage.com`
- `ETCD_S3_REGION`: optional snapshot region, defaults to `eu-central`
- `ETCD_S3_FOLDER`: optional snapshot folder/prefix, defaults to `<cluster-name>/etcd`
- `ETCD_S3_RETENTION`: optional S3-side retention count, defaults to the local etcd retention setting
- `ETCD_S3_BUCKET_LOOKUP_TYPE`: optional S3 lookup type, defaults to `path`

The `Platform Up` workflow accepts the `ETCD_S3_*` settings from either GitHub Actions `secrets` or `vars`. Secrets take precedence when both are set.

When `TF_ETCD_S3_ENABLED=true`, `Platform Up` will fail if the `ETCD_S3_*` settings required to build the k3s snapshot Secret are missing.

## Workflows

### Infra Up

File: `.github/workflows/infra-up.yml`

What it does:

1. Checks out the repo
2. Configures remote Terraform state
3. Runs `terraform fmt -check`
4. Runs `terraform validate`
5. Runs `terraform plan`
6. Refuses the run if the plan deletes or replaces control-plane servers unless `allow_control_plane_replacement=true`
7. Applies the saved Terraform plan
8. Powers on all Terraform-managed servers
9. Publishes the API endpoint in the workflow summary

What it does not do:

- does not install Cilium, CCM, CSI, or Traefik
- does not register the cluster in Argo CD
- does not make nodes `Ready` by itself, because Cilium is installed afterward

After bootstrap, the supported local completion step is:

```bash
make platform-install
```

Use this for:

- first-time provisioning
- normal infra changes
- bringing the cluster back after `Infra Down`

Do not use the normal `Infra Up` path for broad control-plane reprovisioning. If bootstrap or control-plane userdata changes require replacement, roll one control-plane at a time after confirming etcd snapshots are healthy.

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

### Platform Up

File: `.github/workflows/platform-up.yml`

What it does:

1. Loads remote Terraform state
2. Decodes the bootstrap kubeconfig secret
3. Resolves the Hetzner network ID from Terraform outputs
4. Optionally applies the k3s etcd snapshot S3 Secret when `ETCD_S3_*` settings are provided
5. Runs `./bootstrap/scripts/install-platform.sh`
6. Publishes node and Cilium status in the workflow summary

What it installs:

- Cilium
- Hetzner CCM via the official Hetzner chart
- Hetzner CSI via the official Hetzner chart
- Traefik
- cluster access scaffolding
- baseline NetworkPolicies
- optional k3s etcd snapshot S3 config secret in `kube-system`

Use this for:

- first platform bring-up after bootstrap
- re-running the base platform layer after cluster rebuilds
- reconciling the foundational platform before Argo CD fully takes over

### Rotate Control Plane

File: `.github/workflows/rotate-control-plane.yml`

What it does:

1. Loads remote Terraform state
2. Plans a replacement for exactly one Terraform control-plane server key
3. Refuses the run if any additional control-plane replacement would occur
4. Applies the saved Terraform plan
5. Powers servers on and publishes a short summary

Use this for:

- rolling one-by-one control-plane replacement after bootstrap changes
- adopting new k3s control-plane flags such as etcd S3 snapshot configuration
- repairing a single control-plane node without local Terraform access

Recommended flow:

1. Ensure `Platform Up` has already created or refreshed the `k3s-etcd-snapshot-s3-config` Secret when using etcd S3 backups.
2. Run `Rotate Control Plane` for `control-plane-01`.
3. Wait for the node to return and verify cluster health plus etcd snapshots.
4. Repeat for `control-plane-02` and `control-plane-03`.

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
- `REMOTE_CLUSTER_KUBECONFIG_B64` is a bootstrap-only credential for the `Platform Up` workflow. After OIDC and Argo CD ServiceAccount access are established, treat it as transitional and rotate or remove it if you no longer need it.
