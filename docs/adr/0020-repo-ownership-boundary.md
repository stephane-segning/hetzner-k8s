# ADR-0020: Establish the real ownership boundary (and delete what this repo never owned)

## Status

Accepted (2026-07-25).

## Context

The repo had drifted so far from the running cluster that the operator's
stated position was *"I'm scared to modify this terraform, because I don't
know how much it'll affect the prod cluster."* That fear was rational, but the
cause was misidentified: Terraform was not the problem. The problem was that
**the repo claimed to own things it does not own**, so reading it gave no
reliable picture of production.

The trigger was a concrete symptom: `platform/helm-values/cnpg-values.yaml`
declares `tolerations: []`, `resources.requests.memory: 256Mi` and
`monitoring.podMonitorEnabled: true`, while the live cnpg operator ran
`requests 100Mi / limits 200Mi`, kept a control-plane toleration, and had no
PodMonitor. The obvious reading — "Argo isn't syncing our values" — was wrong.

### What was actually verified (home cluster Argo CD, 2026-07-25)

- The live `cnpg` Application is owned by a parent app **`cd-database`**
  (project `infrastructure`, destination `home-remote`), and carries its values
  **inline** as `helm.valuesObject` — precisely the 100Mi/200Mi + control-plane
  toleration observed on the cluster.
- The `hetzner-helm` and `hetzner-platform` ApplicationSets declared in
  `platform/argocd/applications.yaml` **do not exist** (`NotFound`).
- **Zero** of the **175** Argo Applications reference the `hetzner-k8s` repo.
- **101** Applications target this cluster (destination `home-remote`), all
  defined elsewhere.
- Helm release secrets in the cluster exist for exactly three releases:
  `cilium`, `hccm`, `hcloud-csi` — the ones `install-platform.sh` installs.
- **Traefik had no Helm release secret**, yet an Argo `traefik-remote`
  Application owns it and reports `Synced`. Meanwhile `install-platform.sh`
  still ran `helm upgrade --install traefik`. That is contested ownership: any
  `platform-up.yml` run would have put Helm and Argo in a fight over the same
  release.
- Components running with no representation in this repo at all: **Longhorn**
  (`aii-longhorn`, a full CSI stack, 0 PVs bound — provisioned for the GPU
  nodes) and the **NVIDIA device plugin** (`aii-nvidia-device-plugin`).

## Decision

**1. State the boundary explicitly.** This repo owns:

| Layer | Owned here | Owner in reality |
|---|---|---|
| Terraform: network, firewall, servers, API LB, worker volumes | ✅ | this repo |
| `platform/base/` manifests | ✅ | this repo |
| Cilium, Hetzner CCM, Hetzner CSI | ✅ | `install-platform.sh` |
| Traefik | ❌ | Argo `traefik-remote` |
| cnpg, Redis, Alloy, kube-state-metrics | ❌ | Argo, **inline** values |
| Longhorn, NVIDIA device plugin | ❌ | Argo (`aii-*`) |
| GPU nodes `gpu-1`/`gpu-2` | ❌ | manual Robot enrollment |
| Ingress LBs, CSI PVC volumes | ❌ | Hetzner CCM / CSI at runtime |
| ~100 workload Applications | ❌ | Argo, other repos (by design) |

**2. Delete what this repo never owned**, rather than leave it to mislead:

- `platform/argocd/` (both `applications.yaml` and a `README.md` that was
  still a `YOUR_ORG/YOUR_REPO` placeholder)
- `platform/helm-values/{cnpg,redis,alloy,kube-state-metrics,traefik}-values.yaml`
- the corresponding render/validate steps in `tests/render/`

**3. Give up Traefik cleanly.** `install-platform.sh` no longer installs it.
Argo is the single owner.

## Consequences

- `platform/helm-values/` now contains exactly the three files
  `install-platform.sh` reads. If a file is in this directory, it is live.
- `platform-up.yml` is safe to run again — it can no longer contend with Argo
  over Traefik.
- 🧨 **Traefik upgrades/config are no longer possible from this repo.** That is
  the intended consequence, not a regression. Change them where
  `traefik-remote` is defined.
- Fixing cnpg's placement (ADR-0019) must happen in the repo that defines the
  `cd-database` app, by editing its `valuesObject`.
- A pre-existing `Failed to render traefik` warning in `make test` disappears,
  because that render step is gone.
- **This ADR is a snapshot.** Ownership can drift again — a future chart could
  be adopted by Argo without this repo noticing. The check is cheap and worth
  re-running when something surprises you:

  ```bash
  # Which releases does Helm own here?
  kubectl get secrets -A -l owner=helm \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.labels.name}{"\n"}{end}' | sort -u

  # Which Argo Applications target this cluster, and from where?
  kubectl --context <home> -n argocd get applications \
    -o jsonpath='{range .items[*]}{.spec.destination.name}|{.metadata.name}|{.spec.source.repoURL}{"\n"}{end}' \
    | grep '^home-remote'
  ```

## Alternatives considered

- **Make the fiction real** — migrate the home cluster to use this repo as the
  Argo source for cnpg/redis/alloy/kube-state-metrics. Rejected for now: it is
  a much larger change that touches the home cluster's GitOps layout, and it
  would not have reduced the immediate confusion. It stays a viable future
  direction; this ADR does not preclude it.
- **Leave the files with an "aspirational" banner.** Rejected: the files had
  already caused a real misdiagnosis, and a banner does not stop the next
  person from editing `cnpg-values.yaml` and expecting an effect.
