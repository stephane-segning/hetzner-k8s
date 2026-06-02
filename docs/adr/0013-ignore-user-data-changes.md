# ADR-0013: Ignore `user_data` drift on servers; roll cloud-init out via `-replace`

## Status

Accepted

## Context

`user_data` is a `ForceNew` attribute on `hcloud_server`: changing it makes
Terraform plan a destroy-and-recreate of the server. Our cloud-init lives
in `bootstrap/cloud-init/node.yaml`, rendered into every node's
`user_data`. So **any** edit to cloud-init — adding the per-node password
(ADR-0012), tweaking the restore branch, fixing a comment — makes the next
Terraform plan want to replace *every* server at once.

That collides with two existing invariants:

1. The Infra Up workflow's **`Guard control-plane replacements`** step
   fails the run if the plan deletes any control-plane server and
   `allow_control_plane_replacement` is not `true`. So after any cloud-init
   edit, the *next routine Infra Up* (run for any unrelated reason) would
   fail at the guard.
2. Replacing all three control planes simultaneously would **break etcd
   quorum** (ADR-0007 exists precisely to prevent that).

Crucially, cloud-init only runs at **first boot**. An in-place `user_data`
change never reaches an already-provisioned node anyway — so forcing a
replacement on every edit buys nothing for existing nodes; it only creates
a dangerous, guard-blocked plan.

This was raised in review of the ADR-0012 PR: as written, merging the
cloud-init change would have bricked routine Infra Up until someone
performed a full, guard-overriding control-plane rotation.

## Decision

Add `lifecycle { ignore_changes = [user_data] }` to the `hcloud_server`
resource in `terraform/modules/server/main.tf`.

Consequences for how cloud-init changes propagate:

- A cloud-init edit no longer shows up as drift; routine Infra Up stays a
  no-op on healthy nodes.
- To roll a cloud-init change onto a node, replace it deliberately:
  `terraform apply -replace='module.servers.hcloud_server.main["worker-01"]'`.
  `-replace` bypasses `ignore_changes` and recreates the node with the
  *current* rendered `user_data`.
- The **restore flow depends on this**: ADR-0002/0007's first-restore
  branch used to rely on cp-1's restore-mode `user_data` differing from
  normal mode to trigger its replacement. With `ignore_changes`, that
  drift is suppressed, so the Infra Up `Terraform plan` step now adds the
  bootstrap control plane to the explicit `-replace` set in the
  first-restore branch (API unreachable). See `.github/workflows/infra-up.yml`.

## Consequences

- Routine Infra Up is safe after any cloud-init edit — no surprise
  all-node replacement, no guard failure.
- Cloud-init changes become **opt-in per node**, which matches the
  operating model: node replacement is deliberate, recovery-grade work,
  not a side effect of an unrelated apply.
- A node keeps running whatever cloud-init it first booted with until it
  is explicitly replaced. Operators must remember that editing
  `node.yaml` does not retroactively change live nodes — only new/replaced
  ones. This is documented here and in `docs/arc42` § 8.
- The first-restore path must (and now does) name every control plane in
  its `-replace` set, including cp-1, since it can no longer lean on
  `user_data` drift. On a first restore there is no quorum to protect, so
  replacing all CPs together is correct.
- If a future change needs to fan a cloud-init edit across all nodes
  without a restore, the operator does a rolling `-replace` — workers
  freely, control planes one at a time (never simultaneously, to preserve
  quorum), each with `allow_control_plane_replacement=true`.
