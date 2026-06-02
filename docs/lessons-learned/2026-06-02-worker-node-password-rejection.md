# 2026-06-02 — All workers NotReady after reboot: node-password rejection

## Summary

After an operator change that rebooted the worker VMs, all three workers
went `NotReady` (`Kubelet stopped posting node status`) while all three
control planes stayed `Ready`. Root cause: k3s node-password mismatch.
Fixed live in ~30 seconds by deleting the stale per-node Secrets;
prevented from recurring by ADR-0012 (deterministic node password).

## Symptom

```
$ kubectl get no
... worker-1   NotReady   <none>   5d15h
... worker-2   NotReady   <none>   5d15h
... worker-3   NotReady   <none>   5d15h
```

Node condition: `NodeStatusUnknown / Kubelet stopped posting node status`.

On the workers, `journalctl -u k3s-agent`:

```
Waiting to retrieve agent configuration; server is not ready:
/var/lib/rancher/k3s/agent/serving-kubelet.crt: Node password rejected,
duplicate hostname or contents of '/etc/rancher/node/password' may not
match server node-passwd entry, try enabling a unique node name with the
--with-node-id flag
```

Everything else on the workers was healthy: private NIC up (`10.0.0.20-22`),
API LB reachable from the worker (`/livez` → 401), k3s-agent in its retry
loop.

## Root cause

k3s stores `hash(node-password)` in `kube-system` Secret
`<nodename>.node-password.k3s` on a node's first join and rejects later
joins that present a different password. The workers' on-disk
`/etc/rancher/node/password` no longer matched the stored Secret. The
tell: cp-1's Secret was `7m` old (it had re-registered) while the worker
Secrets were `5d15h` old — the stored Secrets were from a different era
than the workers' current on-disk passwords (consistent with an etcd
restore re-introducing older Secrets, and/or a disk/identity change on
reboot).

This was **pre-identified** as debt D-4 in
`docs/arc42/11-risks-and-technical-debt.md` — we knew the mismatch was
possible, we just hadn't closed it.

## Fix (live)

Deleted the three stale worker Secrets; the agents (already retrying every
~7 s) re-registered with their current on-disk passwords and k3s minted
fresh Secrets:

```bash
for n in worker-1 worker-2 worker-3; do
  kubectl -n kube-system delete secret "ssegning-hetzner-k3s-$n.node-password.k3s"
done
```

All six nodes `Ready` within ~30 s. Non-destructive: node-password is a
join-time anti-spoofing token, not workload data. Confirmed the on-disk
password files were present (33 bytes each) before deleting, so the nodes
would re-seed Secrets from a real value rather than mint empty ones.

## Prevention

[ADR-0012](../adr/0012-deterministic-node-password.md): cloud-init now
pre-seeds a **deterministic** `/etc/rancher/node/password` derived from the
stable cluster token + hostname. Every reprovision of a node name presents
the same password, matching the stored Secret through reboot, `-replace`,
and etcd restore. The break-glass deletion above is documented in
`docs/recovery.md` for any residual mismatch.

A one-time Secret sweep is needed for nodes provisioned before ADR-0012
(roadmap item N-5).

## Lessons

- **A known risk left open will eventually fire.** D-4 was in the register
  with a "consider a workflow step" mitigation that we never built.
  Closing risks with code beats logging them.
- **Same failure family, different layer.** Worker CA pinning (ADR-0006),
  cp peer-URL mismatch (ADR-0011), and now node-password (ADR-0012) are
  all "joining-node state must match cluster identity, which our
  reprovision/restore operations invalidate." The general defense is:
  derive joining-node identity deterministically from state that survives
  those operations (the cluster token), rather than from per-VM random
  values.
- **The stale `EXTERNAL-IP` column is a red herring.** `kubectl get no -o
  wide` showed workers with CP public IPs — that was Hetzner CCM's cached
  address mapping not yet reconciled after the reboots, not the problem.
  Don't chase it.
