# ADR-0001: Record architecture decisions

## Status

Accepted

## Context

This repository operates a production k3s cluster on Hetzner Cloud. The
operating model is unusual enough — GH-Actions-only control plane, deterministic node identities, etcd S3 snapshots,
Hetzner-specific networking quirks — that operators returning to the codebase months later need to reconstruct *why*
specific choices were made, not just *what* they are.

`DECISIONS.md` captures the high-level shape of those choices (server types,
CNI, storage, etc.) as a single design document. That format works for the
broad strokes but not for the small, painful decisions that come out of
incidents — for example, "pre-decompress the etcd snapshot before
`--cluster-reset-restore-path` because k3s 1.35.x has a `filepath.Join` bug
on `.zip` paths". These are too narrow for the design doc and too important
to lose.

## Decision

Adopt the [Michael Nygard ADR format](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)
in `docs/adr/`. One Markdown file per decision. Status moves Proposed →
Accepted → Superseded; never delete or rewrite a prior ADR — supersede
with a new one instead. Index lives in `docs/adr/README.md`.

ADRs complement rather than replace `DECISIONS.md`. Use `DECISIONS.md` for
the design overview and rationale of major choices that hold together as a
coherent picture; use ADRs for individual decisions, especially ones learned
from real failures.

## Consequences

- A new operator picking up the repo can read the ADR index and reconstruct
  the chain of reasoning, including the painful debugging shortcuts.
- Adding new significant decisions has a clear home and template; the
  decision-making process is implicitly logged rather than living in
  PR descriptions or commit messages.
- Slight maintenance cost: someone has to remember to write the ADR.
  Mitigated by linking ADR creation to the merge of any
  meaningfully-novel infra-up.yml or cloud-init change.
- The ADR archive is append-only by convention; this preserves the
  historical view even when the current state has moved on, which is more
  valuable than keeping the docs strictly current.
