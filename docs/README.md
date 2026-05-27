# Documentation

Entry point for everything in `docs/`.

## What's here

| Path                                          | When to use                                                                                              |
|-----------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| [`arc42/`](arc42/README.md)                   | Structural architecture documentation. Start here to understand how the system is shaped.                |
| [`adr/`](adr/README.md)                       | Architecture Decision Records. One file per significant decision, especially the ones learned the hard way. |
| [`lessons-learned/`](lessons-learned/README.md) | Chronological post-mortems and longer narratives.                                                       |
| [`recovery.md`](recovery.md)                  | Operational runbook: how to recover the cluster from S3 etcd snapshots.                                 |
| [`bootstrap.md`](bootstrap.md)                | First-time bootstrap and break-glass.                                                                    |
| [`architecture.md`](architecture.md)          | Legacy single-page architecture overview. Being incrementally replaced by `arc42/`.                       |
| [`access.md`](access.md)                      | Human (OIDC) and automation (ServiceAccount) access patterns.                                            |
| [`external-dns.md`](external-dns.md)          | DNS strategy.                                                                                            |
| [`github-actions.md`](github-actions.md)      | Workflow inventory + how to operate via GH Actions.                                                      |
| [`testing-runbook.md`](testing-runbook.md)    | Render and unit test conventions.                                                                        |

## How these fit together

- **`arc42/`** is the canonical reference for *what the system is*.
- **`adr/`** is the canonical record of *why each non-obvious choice
  was made*. Cross-referenced from arc42 § 9.
- **`lessons-learned/`** is the canonical narrative of *how we got
  to those decisions*, in chronological order.
- **`recovery.md`**, **`bootstrap.md`**, and the other top-level docs
  are operational runbooks — short, action-oriented, link back to
  ADRs for the "why".

The macro design rationale lives at the repo root in
[`DECISIONS.md`](../DECISIONS.md). Treat that as a higher-level companion
to the arc42 + ADR set.

## Conventions

- All Markdown uses ATX `#` headings.
- Code spans / inline code use backticks.
- Mermaid diagrams render inline on GitHub and locally with Markdown
  preview.
- ADRs are append-only (supersede; never edit substantively).
- The lessons-learned log gains a new entry whenever an operational
  incident burns more than ~1 PR cycle to resolve.
