# ADR-0012: Deterministic node password to survive reboot, replace, and restore

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
hash, or the agent is rejected. This is an anti-spoofing measure: it
stops a different machine from claiming an existing node's name.

### Why it breaks for us

Three of our routine operations invalidate the match:

1. **Terraform `-replace` of a node** (worker rotation, recovery). The
   new VM has a fresh disk, so it generates a *new* random password,
   but the cluster still holds the Secret from the old VM. → rejected.
2. **etcd restore from an S3 snapshot.** The snapshot contains the
   node-password Secrets from the snapshot's era. After restore, those
   replace whatever was current, so a node whose on-disk password came
   from a later era no longer matches. → rejected. (This is the
   2026-06-02 incident: the snapshot-era Secrets didn't match the
   workers' on-disk passwords from when they joined the post-restore
   cluster.)
3. **Any reprovision that regenerates the password file.**

The manual fix each time is to delete the stale Secret
(`kubectl -n kube-system delete secret <nodename>.node-password.k3s`)
and let the agent re-register — but that is exactly the manual SSH/kubectl
toil the GH-Actions-only operating model is meant to avoid. It was logged
as debt **D-4** in `docs/arc42/11-risks-and-technical-debt.md`.

### Options considered

- **`--with-node-id`** — appends a unique per-machine suffix to the node
  name, so a replaced node never collides with a stale Secret.
  **Rejected:** it breaks our deterministic node-name contract
  (`ssegning-hetzner-k3s-worker-1` etc.), which other things reference,
  and which the whole design leans on.
- **A workflow step that prunes node-password Secrets before replacing
  a node.** Possible, but Infra Up has no cluster kubeconfig today, and
  it doesn't cover the etcd-restore case (the Secret comes back from the
  snapshot).
- **Pre-seed a deterministic password in cloud-init.** Chosen, below.

## Decision

In cloud-init (`bootstrap/cloud-init/node.yaml`), before installing k3s,
write `/etc/rancher/node/password` with a value derived deterministically
from the cluster token and the node's hostname — but only if the file
doesn't already exist:

```bash
if [ ! -s /etc/rancher/node/password ]; then
    NODE_PASSWORD="$(printf '%s' "$K3S_TOKEN:$(hostname)" | sha256sum | cut -d' ' -f1)"
    mkdir -p /etc/rancher/node
    printf '%s\n' "$NODE_PASSWORD" > /etc/rancher/node/password
    chmod 0600 /etc/rancher/node/password
fi
```

`$K3S_TOKEN` is `random_password.k3s_token` from Terraform state, which is
stable across reboots, `-replace`, and restores. `$(hostname)` equals the
k3s node name (we don't override `--node-name`). So **every** provision of
a given node name presents the **same** password, which matches the stored
Secret indefinitely — no rejection on reboot, replace, or restore.

Applies to all roles (control planes and workers) since all of them have
node-password Secrets.

## Consequences

- Reboot, Terraform `-replace`, and etcd restore no longer leave a node
  `NotReady` on a password mismatch. Closes debt **D-4** and removes the
  need for the manual "delete the Secret" remediation in the common case.
- **One-time migration required.** Existing nodes have Secrets created
  from their *old random* passwords. After this change is deployed, the
  next reboot/replace of an existing node will present the new
  deterministic password, which won't match the old Secret until the
  Secret is deleted once. Operators should, on first rollout, delete the
  existing `*.node-password.k3s` Secrets (or accept that each node
  self-heals the first time its Secret is cleared). New nodes are correct
  from the start.
- **Security trade-off.** The password is now derivable by anyone holding
  the cluster token plus the (public) node name. This adds no meaningful
  exposure: the cluster token is already the join secret — possessing it
  already allows joining as any node and deleting Secrets. The node
  password was never an independent boundary in this design.
- **`/etc/rancher/node/password` is now load-bearing and deterministic.**
  If an operator wants to rotate it, they must rotate the cluster token
  (which has wider consequences) or accept a one-off Secret deletion.
- The manual remediation (delete the Secret) remains valid and is
  documented in `docs/recovery.md` as a break-glass for any residual
  mismatch.
