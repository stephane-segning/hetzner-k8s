# ADR-0021: Infra Up gets a read-only `plan_only` mode

## Status

Accepted (2026-07-25).

## Context

GitHub Actions is the only supported control surface for this cluster
(`AGENTS.md`, `CLAUDE.md`). But **every** Infra Up run applied. There was no
supported way to ask *"what would this do?"* short of a break-glass local
`terraform plan`, which requires the operator to have the S3 backend
credentials and the `hcloud` token on their laptop — exactly the path the
operating model tells them not to take.

The practical result, in the operator's own words on 2026-07-25:

> *"I'm scared to modify this terraform, because I don't know how much it'll
> affect the prod cluster."*

That is a tooling gap, not a knowledge gap. The workflow already computes
everything needed to answer the question — it runs `terraform plan -out`, then
`terraform show -json` in the control-plane guard — and then threw the answer
away by proceeding straight to `apply`.

This matters more here than in a typical repo because the destructive
operations are genuinely destructive: `replace_nodes` destroys and recreates
VMs, `allow_control_plane_replacement` can break etcd quorum (ADR-0007), and
`restore_from_s3` can wipe a healthy cluster (ADR-0004). Those are precisely
the runs an operator most wants to preview.

## Decision

Add a `plan_only` boolean input (default `false`). When `true`, the workflow
runs `init` → `fmt` → `validate` → `plan` → the control-plane guard → a new
**blast radius summary**, and then stops. `apply` and every post-apply step
are skipped via `if: ${{ !inputs.plan_only }}`.

Two details that make it useful rather than merely safe:

1. **A blast-radius summary, not a raw plan.** A new step groups the planned
   actions from `tfplan.json` by kind — `➕ create`, `✏️ update in place`,
   `🧨 REPLACE`, `❌ DESTROY` — into `GITHUB_STEP_SUMMARY`. The distinction
   that matters operationally is *replace/destroy vs. everything else*, and a
   full plan buries it. "No changes" is stated explicitly.
2. **The control-plane guard reports instead of failing.** In a normal run the
   guard `exit 1`s when Terraform wants to replace a control plane without
   `allow_control_plane_replacement=true`. Under `plan_only` it prints the same
   message and continues, so a preview does not end in a red ✗. Nothing is
   applied in either case, so failing added no safety — only noise.

`plan_only` composes with every other input. Previewing
`replace_nodes=worker-03` or `restore_from_s3=true` is the highest-value use
of this mode, and is explicitly supported.

## Consequences

- There is now a supported, credential-free, read-only way to see the blast
  radius of any Infra Up before running it. Break-glass local `terraform plan`
  is no longer the only option.
- The summary is generated from `tfplan.json`, which the guard step already
  produced — no extra Terraform invocation, no extra runtime.
- ⚠️ **A plan is a snapshot, not a guarantee.** It reflects state at plan time;
  drift between the preview and a later apply is still possible. Treat a clean
  preview as strong evidence, not a contract.
- ⚠️ **`plan_only` cannot preview cloud-init changes.** `user_data` is under
  `ignore_changes` (ADR-0013), so a modified `node.yaml` shows **no diff** in
  the plan even though it would change any node that is later replaced. This
  is the one blind spot; caveats § 5.2 already covers it.
- The mode is genuinely used, not a dormant switch: it exists because the
  operator needed it to regain confidence in the supported surface.

## Alternatives considered

- **A separate `infra-plan.yml` workflow.** Rejected: it would duplicate the
  ~140 lines of backend wiring, `TF_VAR_*` env, and the replace/guard logic,
  and the copy would drift from `infra-up.yml` — the exact failure mode this
  repo has been fighting.
- **Always post the plan summary, even on applying runs.** Kept, in fact — the
  summary step is not gated, so normal runs get the blast radius in their
  summary too. Only `apply` and the post-apply gates are conditional.
- **Making `plan_only` the default.** Rejected: it would turn every existing
  operator habit into a no-op and invite a second "did it actually run?"
  confusion.
