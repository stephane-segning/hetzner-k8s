# 1. Introduction and Goals

## 1.1 Requirements overview

`ssegning-hetzner-k3s` is a small, opinionated, production Kubernetes
cluster running on Hetzner Cloud (Nuremberg, `nbg1` by default). It hosts
the workloads listed in `docs/architecture.md` and the platform layer
listed in `platform/`: Cilium, Hetzner CCM/CSI, Traefik, CloudNativePG,
Redis HA, Keycloak, Knative, GitHub Actions Runner Controller,
OpenTelemetry, etc. — all reconciled by a home-cluster Argo CD against
this repo.

The cluster is **infrastructure as code** in the strict sense: every
provisioning, recovery, and platform-management operation is a workflow
in `.github/workflows/`. There is no documented operator path that
requires SSH to a node.

## 1.2 Quality goals

In rough priority order:

1. **Recoverable from S3 etcd snapshots without manual intervention.**
   The cluster's entire control plane can be lost (servers destroyed,
   region incident, accidental `terraform destroy`) and the operator can
   trigger `Infra Up` with `restore_from_s3=true` to get the cluster back
   with workloads intact. No SSH required for the happy path.
2. **Deterministic node identities.** Node names, private IPs, and roles
   are derived from Terraform variables and are stable across recreate
   operations. cp-1 always exists at `10.0.0.10`, worker-2 at `10.0.0.21`,
   etc.
3. **Single, supported control surface.** GH Actions workflows are the
   only path that's expected to work and is documented. Local
   `terraform apply` is a break-glass.
4. **Cost-bounded.** ~€185-190/month net for the Cloud project: 3×CPX32
   CPs, 4×CPX42 workers, 3 Hetzner LBs, Object Storage, CSI volumes.
   Re-baselined 2026-07-25 from the original ~€100 (§ 10.5 explains why).
   Off-cloud Robot GPU servers bill separately. See `Makefile`
   `show-costs`.
5. **Observable enough to fail loudly.** Workflows self-validate (e.g.
   the Infra Up `/livez` gate), so green-on-workflow means
   reachable-cluster. Argo CD in the home cluster surfaces any drift in
   platform manifests.

## 1.3 Stakeholders

| Role                                      | Concerns                                                                             |
|-------------------------------------------|--------------------------------------------------------------------------------------|
| Cluster operator (you, future you)        | Reliable recovery; minimal toil; clear runbooks                                      |
| Workload owners (Keycloak, CNPG, Redis,…) | Cluster comes back from incidents without losing my PVC data                         |
| Home-cluster Argo CD                      | Stable API endpoint, working `argocd-manager` ServiceAccount token                   |
| Future contributors                       | Can read the code and ADRs and understand why each surprising thing is the way it is |
