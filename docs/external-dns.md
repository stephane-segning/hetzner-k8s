# External DNS on Hetzner

This document studies whether `external-dns` is useful for this platform and what the Hetzner integration looks like.

## Short answer

Yes.

Hetzner supports `external-dns`, but not as an in-tree provider in `external-dns` itself.
The supported Hetzner path is:

- `external-dns`
- provider mode: `webhook`
- webhook: `hetzner/external-dns-hetzner-webhook`

Hetzner documents this integration as an official Kubernetes integration in the new Console DNS platform.

## What exists today

Current state of upstream/provider support:

- `external-dns` uses a generic webhook provider model
- Hetzner provides an official webhook implementation: `hetzner/external-dns-hetzner-webhook`
- The webhook is deployed as a sidecar through the `external-dns` Helm chart

Relevant references:

- Hetzner DNS docs list `external-dns-hetzner-webhook` as an official integration
- Hetzner webhook quickstart shows `external-dns` with `provider.name=webhook`

## When it helps this cluster

`external-dns` is useful when you want DNS records to follow Kubernetes resources automatically.

Main benefits here:

1. ingress hostnames can be created automatically for applications behind Traefik
2. GitOps can manage app exposure without manual DNS changes
3. app onboarding gets simpler when many hostnames are involved
4. DNS ownership stays in the same Hetzner project and API model as the rest of the platform

## When it does not help much

`external-dns` is not especially useful for:

1. the Kubernetes API load balancer hostname

Reason:

- the API endpoint is Terraform-owned and should remain explicit and stable
- it is usually a single record that changes rarely

So:

- manage API DNS explicitly
- use `external-dns` for workload/ingress DNS

## Requirements

To use `external-dns` with Hetzner DNS you need:

1. zones hosted in Hetzner DNS / Hetzner Console
2. a Hetzner API token with access to the relevant project/zones
3. `external-dns`
4. `hetzner/external-dns-hetzner-webhook`

## Recommended deployment pattern

For this cluster, if you enable it, I recommend:

- deploy `external-dns` in its own namespace
- use Hetzner webhook sidecar
- set `domainFilters` to only the zones this cluster should manage
- use TXT ownership records with a unique owner id per cluster
- start with `policy: upsert-only`

This reduces blast radius during the first rollout.

## Suggested scope for this installation

Good initial scope:

- only manage app/ingress records
- do not manage API endpoint DNS
- do not manage unrelated zones from the same token/project if avoidable

## Risks and caveats

1. DNS becomes part of runtime reconciliation, not just explicit Terraform state
2. mis-scoped filters can cause unwanted record changes
3. TXT ownership records must be planned if multiple controllers or clusters share domains
4. webhook/provider behavior should be tested against your exact use of `Ingress` or other sources

## Recommendation

Recommendation for this repo:

- do not make `external-dns` mandatory for first bootstrap
- add it after base networking, ingress, and access are proven
- use it if you plan to host multiple ingress-backed applications on Hetzner DNS

## Bottom line

`external-dns` can yield real benefits for this installation, especially once app ingress grows.

It is a good fit for:

- GitOps-managed ingress DNS
- reducing manual A/CNAME record work
- keeping Hetzner-hosted DNS aligned with Kubernetes state

It is not required to get the base cluster working and should be treated as an optional phase after core cluster validation.
