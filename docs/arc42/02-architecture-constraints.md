# 2. Architecture Constraints

Constraints we treat as fixed when making design choices. Some are
external (Hetzner Cloud, k3s, GH Actions); some are operational policy
chosen by the cluster owner.

## 2.1 Technical constraints

| Constraint                                                                        | Source                                                                |
|-----------------------------------------------------------------------------------|-----------------------------------------------------------------------|
| Hetzner Cloud as IaaS                                                             | Operator choice (cost, location)                                      |
| Servers must be in `nbg1` (Nuremberg) by default                                  | Cost / latency; configurable via `TF_VAR_location`                    |
| Network is a single Hetzner private network `10.0.0.0/16`                         | Hetzner private-network model                                         |
| OS is Ubuntu 24.04 LTS (Noble Numbat)                                             | DECISIONS.md; long support window                                     |
| Distribution is k3s (`v1.35.3+k3s1` pinned)                                       | DECISIONS.md; single-binary, lightweight                              |
| Embedded etcd for HA                                                              | DECISIONS.md; alternative is external datastore                       |
| External cloud-provider mode; Hetzner CCM owns node ProviderIDs and LoadBalancers | DECISIONS.md; required for Hetzner CCM to attach LB targets correctly |
| CNI is Cilium with `--flannel-backend=none --disable-network-policy`              | DECISIONS.md                                                          |
| `local-storage` storage class disabled; persistent storage via Hetzner CSI only   | DECISIONS.md                                                          |
| Swap disabled                                                                     | Kubernetes-standard; cloud-init removes it                            |
| Terraform state in Hetzner Object Storage via S3 backend                          | AGENTS.md                                                             |
| Kubernetes API endpoint via a dedicated Terraform-managed Hetzner LB (`:6443`)    | DECISIONS.md                                                          |
| Ingress LBs are CCM-managed from `Service.type=LoadBalancer`; not in Terraform    | DECISIONS.md (split ownership avoidance)                              |
| Direct public ingress to node ports disabled                                      | DECISIONS.md (security posture)                                       |
| Public SSH to nodes disabled by default; recovery flow must not require it        | AGENTS.md                                                             |
| OIDC against Keycloak for human access; ServiceAccount tokens for automation      | DECISIONS.md                                                          |

## 2.2 Organizational constraints

| Constraint                                                     | Source / why                                                                                |
|----------------------------------------------------------------|---------------------------------------------------------------------------------------------|
| GH Actions is the supported control surface                    | AGENTS.md — `infra-up`, `infra-down`, `infra-destroy`, `platform-up`, `verify-etcd-backups` |
| No commit of `terraform.tfvars` or backup files                | AGENTS.md                                                                                   |
| Argo CD lives in a separate home cluster, not in this one      | DECISIONS.md (GitOps controller survives remote cluster issues)                             |
| Default topology: 3×CPX22 control planes, 2-3×CPX42 workers    | DECISIONS.md (cost, HA)                                                                     |
| Routine control-plane replacement is not a supported operation | AGENTS.md — recovery-grade work, gated by `allow_control_plane_replacement`                 |

## 2.3 Conventions

- Cloud-init lives in `bootstrap/cloud-init/node.yaml` and is templated by
  Terraform via `templatefile`. Template uses `${...}` interpolation; bash
  uses `${...}` parameter expansion. Conflicts are escaped as `$${...}`.
- Workflows pass GH Action secrets and `vars.` into `TF_VAR_*` environment
  variables; Terraform reads them as inputs.
- Scripts under `bootstrap/scripts/` are bash + shellcheck-clean; default
  shell on the operator's laptop is zsh, so any scripts must be
  POSIX-portable or explicitly invoked under bash.
- Markdown docs use ATX-style `#` headings.
- ADRs are append-only (Michael Nygard format); supersession is the
  mechanism for change.
