# Architecture Decision Records

This directory captures significant architecture and operating-model decisions
for the Hetzner k3s cluster, in the **Michael Nygard ADR** format.

Each ADR is a small Markdown file capturing one decision. The intent is not to
replicate everything in `DECISIONS.md` (which is a wider design discussion)
but to record the *individual choices* that have load-bearing consequences,
including the painful ones learned the hard way.

## Index

| #     | Title                                                                       | Status     |
|-------|-----------------------------------------------------------------------------|------------|
| 0001  | [Record architecture decisions](0001-record-architecture-decisions.md)      | Accepted   |
| 0002  | [Restore etcd from S3 via the Infra Up workflow](0002-restore-etcd-from-s3-via-infra-up.md) | Accepted |
| 0003  | [Pre-decompress snapshot before `--cluster-reset-restore-path`](0003-pre-decompress-snapshot-before-cluster-reset.md) | Accepted |
| 0004  | [Idempotent restore via `INSTALL_K3S_SKIP_ENABLE` and a sentinel](0004-idempotent-restore-skip-enable-sentinel.md) | Accepted |
| 0005  | [Bring up the Hetzner private NIC explicitly in cloud-init](0005-bring-up-private-nic-in-cloud-init.md) | Accepted |
| 0006  | [Force-replace workers on restore](0006-force-replace-workers-on-restore.md) | Accepted   |
| 0007  | [Gate non-bootstrap CP `-replace` on API reachability](0007-gate-cp-replace-on-api-reachability.md) | Accepted |
| 0008  | [Self-validate Infra Up via `/livez` gate](0008-self-validate-infra-up-via-livez-gate.md) | Accepted |
| 0009  | [Use `mc` for inline S3 snapshot download during restore](0009-mc-for-inline-s3-download-during-restore.md) | Accepted |
| 0010  | [Override `etcd-s3=false` on the cluster-reset CLI](0010-etcd-s3-false-on-cluster-reset.md) | Accepted |
| 0011  | [Pass `--node-ip` and `--advertise-address` to cluster-reset](0011-node-ip-on-cluster-reset.md) | Accepted |
| 0012  | [Stable per-node password to survive reboot/replace/restore](0012-deterministic-node-password.md) | Accepted |
| 0013  | [Ignore `user_data` drift; roll cloud-init out via `-replace`](0013-ignore-user-data-changes.md) | Accepted |
| 0014  | [Exclude control planes from external LoadBalancer target pools](0014-exclude-control-planes-from-external-lb-targets.md) | Accepted |
| 0015  | [Disable k3s's bundled metrics-server (platform GitOps owns it)](0015-disable-bundled-metrics-server.md) | Accepted |

## Template

```markdown
# ADR-XXXX: Title in imperative

## Status

Accepted | Proposed | Deprecated | Superseded by ADR-YYYY

## Context

What is the issue we are addressing? What is the operational, technical, or
organizational situation that makes the decision necessary? Include enough
context that a reader six months from now understands without external docs.

## Decision

The choice we made, in one or two sentences first, then the detail. Be
specific. Cite k3s flags, file paths, workflow steps where relevant.

## Consequences

What becomes easier or harder. Operational impact. Failure modes the
decision opens or closes. Future work this enables or precludes.
```

## Conventions

- **One decision per file.** If a follow-up overturns or refines a decision,
  open a new ADR and set the prior ADR status to `Superseded by ADR-XXXX`.
- **Status moves forward only.** Once Accepted, don't edit substantively;
  supersede instead.
- **Reference real artifacts.** Cite the workflow YAML line, the cloud-init
  block, the k3s source file. ADRs should let someone read the actual code
  with a clear map of *why* it looks that way.
- **Include the failure mode** the ADR closes whenever the decision came
  from a real incident. The point is to keep the next person from
  re-discovering the same trap.
