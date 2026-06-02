# ADR-0012: Stable per-node password to survive reboot, replace, and restore

## Status

Accepted

## Context

On 2026-06-02, after an operator change that rebooted the worker VMs,
all three workers went `NotReady` with kubelet "stopped posting node
status". The k3s-agent journals showed:

```
Waiting to retrieve agent configuration; server is not ready:
/var/lib/rancher/k3s/agent/serving-kubelet.crt: Node password rejected,
duplicate hostname or contents of '/etc/rancher/node/password' may not
match server node-passwd entry, try enabling a unique node name with the
--with-node-id flag
```

### How k3s node passwords work

On a node's **first** join, k3s reads `/etc/rancher/node/password` (or
generates a random value and writes it there), and the server stores a
hash of it in a `kube-system` Secret named `<nodename>.node-password.k3s`.
On every subsequent join, the presented password must match the stored
hash, or the agent is rejected. This stops a different machine from
claiming an existing node's name.

### Why it breaks for us

Three of our routine operations invalidate the match:

1. **Terraform `-replace` of a node.** The new VM has a fresh disk, so it
   generates a *new* random password, but the cluster still holds the
   Secret from the old VM. → rejected.
2. **etcd restore from an S3 snapshot.** The snapshot contains the
   node-password Secrets from the snapshot's era, which after restore no
   longer match a node whose on-disk password came from a later era. →
   rejected. (This is the 2026-06-02 incident.)
3. **Any reprovision that regenerates the password file.**

The manual fix is to delete the stale Secret and let the agent
re-register, which is exactly the SSH/kubectl toil the GH-Actions-only
operating model avoids. Logged as debt **D-4**.

### Options considered

- **`--with-node-id`** — appends a unique per-machine suffix to the node
  name. **Rejected:** breaks our deterministic node-name contract.
- **Derive the password from `hash(k3s_token + hostname)` in cloud-init.**
  Considered and initially implemented, then **rejected on review:**
  (a) it collapses a security boundary — anyone holding the shared k3s
  join token could compute any node's identity password, whereas the
  node password is supposed to be the *separate* check that stops a token
  holder from claiming an existing node; (b) `$(hostname)` is fragile
  (FQDN / uppercase) and must be normalized to the k3s node name.
- **A stable per-node secret held in Terraform state.** Chosen, below.

## Decision

Generate a **per-node** password in Terraform
(`random_password.node_password`, keyed by the deterministic node keys
`control-plane-0N` / `worker-0N`), render it into each node's cloud-init
`user_data`, and have cloud-init write it to `/etc/rancher/node/password`
before installing k3s:

```hcl
# terraform/envs/prod/main.tf
resource "random_password" "node_password" {
  for_each = toset(concat(
    [for i in range(var.control_plane_count) : format("control-plane-%02d", i + 1)],
    [for i in range(var.worker_count) : format("worker-%02d", i + 1)],
  ))
  length  = 32
  special = false
}
```

```bash
# bootstrap/cloud-init/node.yaml (reached only when k3s is not yet active)
mkdir -p /etc/rancher/node
printf '%s\n' "${node_password}" > /etc/rancher/node/password
chmod 0600 /etc/rancher/node/password
```

Terraform state is stable across reboot, `-replace`, and restore, so a
given node always presents the same password and always matches the
stored Secret. The write is unconditional (no `[ ! -s ]` guard): the
bootstrap script early-exits if k3s is already active, so we only reach
the write pre-install, where overwriting is correct and avoids a
stale-file mismatch.

Applies to all roles (control planes and workers).

## Consequences

- Reboot, `-replace`, and etcd restore no longer leave a node `NotReady`
  on a password mismatch. Closes debt **D-4**.
- **Independent of the join token.** A leaked k3s join token does not by
  itself reveal node passwords — they are separate per-node random values
  in Terraform state. (The rendered password does still live in the
  node's `user_data`, so an attacker who can read a specific node's
  `user_data` — via the Hetzner API or that node's disk — learns that
  node's password. Full isolation would require not shipping the password
  in `user_data` at all, which conflicts with the chicken-and-egg of a
  not-yet-joined node. The per-node-secret design closes the token-reuse
  hole specifically called out in review while keeping determinism.)
- **Terraform state holds N additional secrets** (`random_password.node_password`).
  State is already sensitive (it holds `random_password.k3s_token`), so
  this is a marginal increase in the same blast radius.
- **Existing nodes are unaffected until replaced.** A node provisioned
  before this change keeps its old random on-disk password and its
  matching Secret — they are mutually consistent, so the node stays
  healthy through reboots. It adopts the Terraform-held password the next
  time it is `-replace`d (which, per the operating model, is a deliberate
  recovery/migration action). No proactive migration is required; see
  the roadmap N-5 note for the optional accelerated path.
- Rolling this change out is gated by ADR-0013 (`ignore_changes =
  [user_data]`), which prevents the new `user_data` from forcing a
  surprise all-node replacement on the next routine Infra Up.
- The manual "delete the Secret" remediation remains valid for any
  residual mismatch and is documented in `docs/recovery.md`.
