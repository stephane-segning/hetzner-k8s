# 2026-07-25 — Control-plane resize: two wrong diagnoses and an empty fstab

## Summary

A cost review ("the bill is €220, not €100") turned into a reliability
investigation ("the CPs keep disappearing"), which produced a control-plane
resize CPX22 → CPX32 (**ADR-0018**). The resize itself then broke one of the
three control planes: cp-1 came back with an **empty `/etc/fstab`**, leaving
`/` mounted read-only and k3s crash-looping 21 times with an error that named
a TLS certificate.

Nothing was lost. Total exposure was ~10 minutes at 2/3 etcd quorum.

## Timeline (UTC, 2026-07-25)

| Time | Event |
|---|---|
| ~14:33 | All three CPs rescaled CPX22 → CPX32. `/etc/fstab` rewritten on cp-2 (558 B, fine) and cp-1 (**0 B**) |
| 14:39 | cp-1: k3s crash-looping, `read-only file system`. Operator reboots — no help |
| ~14:45 | Diagnosis: `/` is `ro`; fs is **clean**; fstab is empty |
| 14:48 | `remount,rw` + fstab rebuilt from cp-1's own `blkid` + `reset-failed` → k3s `active` |
| 14:49 | All 9 nodes Ready, 3/3 etcd voters |
| 15:43 | Deliberate reboot test: `/` comes up `rw`, k3s restart counter 0, **0 failed units**, cloud-init `done` |

## What actually went wrong

### 1. The dashboard blamed CPU. It was memory.

The presenting symptom was CPs going `NotReady` while `ssh` kept working. The
dashboard attributed it to CPU. Measurement said otherwise: load 0.25 on
2 vCPU, **steal 0.0 %**, PSI `cpu` full = 0. Meanwhile memory sat at ~480 MB
available with `k3s-server` alone at 2.46 GiB, and etcd logged 5,463
`apply request took too long` plus 49 `failed to send out heartbeat`.

The real chain: memory exhaustion → etcd/raft lease-read latency → kubelet
misses its Node Lease renewal (~40 s grace) → node marked `NotReady`, **while
the machine is perfectly healthy** — hence working SSH.

### 2. The proposed fix was already implemented.

The instinct was "stop workloads landing on the CPs." The
`control-plane=true:NoSchedule` taint was already present and un-drifted on
all three. What was actually true — and different — is that 8 Deployment pods
*tolerated* it via `operator: Exists`. That is a chart problem, not a taint
problem (**ADR-0019**). It was also, on its own, too small to matter:
~350 MiB against a 2.5 GB process on a 3.7 GiB box.

### 3. k3s's error named the victim, not the cause.

```
level=fatal msg="Error: preparing server: failed to generate server dependencies:
remove /var/lib/rancher/k3s/server/tls/client-kube-proxy.crt: read-only file system"
```

This reads like a certificate/TLS problem. It is a **filesystem** problem, and
"read-only file system" in turn did **not** mean a damaged disk:
`Filesystem state: clean`, zero `EXT4-fs` errors, zero I/O errors, 2×
`slow fdatasync` in two days. The disk was fine throughout.

The mechanism: the kernel cmdline mounts `/` as `ro` on *every* boot
(`root=UUID=… ro`); `systemd-remount-fs` is what makes it `rw`, and it does so
**by reading `/etc/fstab`**. An empty fstab means it has nothing to do — so it
exits `SUCCESS` and `/` stays read-only. Every other failed unit
(`cloud-init` ×4, `snapd`, `fail2ban`, `grub-common`, `k3s-bootstrap`) was
downstream of that single fact, and all of them recovered on their own once
`/` was writable — which retroactively confirmed the diagnosis.

## Root cause of the truncation — honest uncertainty

**Not established.** What was ruled out, with evidence:

- **cloud-init** — `status: not started` on the failing boot, instance-id
  unchanged (`135304844`, so no per-instance re-run), and
  `bootstrap/cloud-init/node.yaml` declares no `mounts:`/`growpart`. On the
  post-fix boot cloud-init completed successfully **without** touching fstab.
- **Disk corruption** — filesystem state `clean`, no kernel errors.
- **Disk upgrade side-effect** — the disk was never resized (still 76.3 GiB).

The leading hypothesis is that the rescale's power-off landed mid-rewrite of
`/etc/fstab`: with ext4 `data=ordered`, a truncate can be committed while the
data write is still in flight, yielding a 0-byte file. Both nodes' fstab
mtimes cluster at ~14:33 (cp-1 14:33:46, cp-2 14:33:54), which fits. It
remains a hypothesis, and it is recorded as one.

## What changed as a result

- **ADR-0018** — CPs are `CPX32`; `vars.tf` + all three workflow fallbacks
  updated together (leaving any behind would rescale them back down).
- **ADR-0019** — workload operators off the CPs where this repo owns the
  chart; explicitly documents which components *must keep* tolerating the
  taint (`cilium-operator`, CCM, CSI node DaemonSet, coredns) because they
  are bootstrap-critical.
- **caveats § 8** — the rescale/fstab trap, indexed by symptom, with a
  ruling-out procedure and the recovery commands.
- **arc42 § 10.5 / README / Makefile** — cost re-baselined from ~€100 to
  ~€185-190 net, with the four reasons it moved.

## Lessons

1. **Verify the premise before agreeing with it.** Two confident diagnoses —
   "the CPs are too small (CPU)" and "workloads are landing on the CPs" — were
   both wrong in their specifics, and both would have produced work that fixed
   nothing.
2. **An error message names the component that noticed, not the one that
   failed.** k3s said "certificate"; the fault was three layers down.
3. **"Read-only filesystem" ≠ "broken disk."** Check `Filesystem state` and
   `dmesg` before escalating to fsck/rescue/rebuild. Here the difference was a
   two-minute fix versus a node rebuild.
4. **Rescale ≠ replace.** `server_type` is not `ForceNew`; in-place
   `ChangeType` avoids cloud-init re-runs and etcd rejoins. But it still power
   cycles the node — one etcd voter at a time, always.
5. **Prove persistence deliberately.** The reboot test (run while quorum was
   healthy) is what turned "it works now" into "it survives a boot."
6. **Correct the record when evidence contradicts you.** Two claims made
   during this investigation were retracted mid-flight: a "1.1 GB etcd db
   can't fit in page cache" theory (the db is 54 MB; the 1.1 GB was
   WAL+snapshots) and an "orphaned Traefik LB costing €7/mo" (the invoice's
   517 h + 60 h = 577 h ≈ one full billing period — one LB replaced, not two
   running).
