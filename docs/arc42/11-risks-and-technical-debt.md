# 11. Risks and Technical Debt

## 11.1 Risks

| ID  | Risk                                                                                            | Impact                                                                                          | Likelihood | Mitigation                                                                                     |
|-----|-------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|------------|-------------------------------------------------------------------------------------------------|
| R-1 | Single-region (`nbg1`) deployment                                                                | Whole-cluster outage on Hetzner regional incident                                                | low        | Accepted; cost-driven. Snapshots in S3 (still potentially same-region) — consider replicating cross-region |
| R-2 | All etcd backup tooling is in one bucket                                                          | Bucket compromise / accidental delete loses snapshots                                            | low        | Bucket versioning + lifecycle policy. Currently relies on Hetzner Object Storage default        |
| R-3 | `K3S_TOKEN` lives in Terraform state                                                              | State leak = ability to join the cluster as a node                                              | low        | State encrypted via S3 server-side; access via GH Action secrets only                          |
| R-4 | k3s 1.35.x has the `decompressSnapshot` doubling bug                                              | Future restore could fail if our workaround stops working                                       | medium     | Pinned k3s version; ADR-0003 workaround. Revisit on upgrade — fix likely upstream eventually   |
| R-5 | Hetzner private NIC race is undocumented upstream                                                 | A future Hetzner provider / cloud-init combination might break our `ensure_private_nic`         | low        | Self-healing function is idempotent and broad in its NIC selection                              |
| R-6 | Sentinel file `/var/lib/rancher/k3s/.recovery-restored` is a load-bearing manual convention      | Deletion (manual or by a tool) could cause re-restore on next reboot, destroying live data       | low        | Documented in ADR-0004 and recovery.md; sentinel mode bits `0600`                              |
| R-7 | etcd S3 credentials in cloud-init `user_data` during restore                                      | Same trust boundary as `HCLOUD_TOKEN` (already there); leak via Hetzner API access              | low        | Rotate creds after restore; `mktemp -d` config dir for `mc`                                    |
| R-8 | Restore relies on `dl.min.io` reachability during cloud-init                                      | If MinIO mirror is down at restore time, restore fails loudly                                   | very low   | Loud failure is acceptable; could mirror `mc` to our own bucket if frequency increases          |
| R-9 | Argo CD home cluster is also single-region                                                        | If both clusters in same region go down, no GitOps reconciliation                               | low        | Accept for now; consider home cluster cross-region                                              |
| R-10 | Cilium identity reshuffle after restore                                                          | Brief network policy mismatch on first reconverge                                                | low        | Self-healing within minutes; informational, not actionable                                      |

## 11.2 Technical debt

| ID    | Debt                                                                                              | Cost of keeping                                                                                 | Plan                                                                  |
|-------|---------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|----------------------------------------------------------------------|
| D-1   | No automated render-and-yamllint of cloud-init                                                    | YAML/heredoc indent traps not caught until live boot                                            | Add a render-with-vars step to `make test`                            |
| D-2   | ADR-0003 / 0010 are upstream-bug workarounds                                                      | Maintenance burden; might bitrot on k3s upgrade                                                  | Open / track an upstream k3s issue; remove the workaround when fixed |
| D-3   | Hetzner CSI's stale `VolumeAttachment` cleanup is noisy after restore                              | First-reconcile is loud in logs / events                                                         | Cosmetic; can be addressed by a controller patch if it becomes confusing |
| D-4   | Node passwords (`<nodename>.node-password.k3s` Secrets) can conflict on CP re-replace             | Need ADR-0007 workaround                                                                          | Consider a workflow step that deletes the relevant Secret pre-replace |
| D-5   | Test coverage is mostly static (`terraform fmt/validate`, YAML render); no live integration tests | Real bugs only surface in production                                                              | Out of scope; cluster too expensive for ephemeral CI cluster          |
| D-6   | The `make bootstrap` local script path is documented as break-glass but not regularly tested      | Likely to bitrot                                                                                  | Either delete it or fold its checks into a workflow                  |
| D-7   | Etcd S3 bucket isn't versioned / lifecycled                                                       | Accidental delete = full loss; no point-in-time recovery older than retention                   | Enable bucket versioning + lifecycle rule for cold storage           |
| D-8   | `restore_from_s3` defaults to `false` but the cloud-init code path is always present              | Maintenance surface; one more branch to keep working                                              | Keep it; restore is a critical path and the cost is small             |
| D-9   | No automated reminder to flip `restore_from_s3` back to false after a recovery                    | If the operator forgets, next routine Infra Up could redo restore on already-restored cluster   | The sentinel + API-reachability gate makes this safe in practice. Document the post-recovery PR pattern more prominently in `docs/recovery.md` |

## 11.3 Decisions deferred

- Cross-region or off-Hetzner copy of etcd snapshots (cost vs. risk).
- Cross-region Argo CD home cluster (cost vs. risk).
- Replacing the in-place restore mechanism with an out-of-band tool
  (e.g. `etcdutl snapshot restore` directly) — would sidestep more k3s
  bugs but adds a deeper integration surface.
- Moving to Talos or k0s if k3s' restore quirks become recurring.
