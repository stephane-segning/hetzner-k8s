# arc42 — Architecture documentation

This directory follows the [arc42 template](https://arc42.org/overview)
structure (12 sections, one file each) describing the architecture of the
`ssegning-hetzner-k3s` cluster.

arc42 sits **alongside** the ADR archive and the lessons-learned log:

- **arc42** is the structural reference: how the system is shaped, what
  pieces it has, what runs at what time, what constraints bound it.
- **ADRs** record specific decisions made within that shape, especially
  ones that come out of operational experience.
- **Lessons learned** capture chronological narratives — useful when
  someone returns months later and wants to know *why* a particular
  decision was made.

## Sections

| #  | File                                                       | What it covers                                                |
|----|------------------------------------------------------------|---------------------------------------------------------------|
| 1  | [Introduction and Goals](01-introduction-and-goals.md)     | Purpose, top quality goals, stakeholders                      |
| 2  | [Architecture Constraints](02-architecture-constraints.md) | Technical & operational constraints we can't change           |
| 3  | [System Scope and Context](03-context-and-scope.md)        | What's in the system, what's outside, what crosses            |
| 4  | [Solution Strategy](04-solution-strategy.md)               | Big-picture decisions and how the parts hang together         |
| 5  | [Building Block View](05-building-block-view.md)           | Static decomposition: modules, files, what owns what          |
| 6  | [Runtime View](06-runtime-view.md)                         | Key scenarios: Infra Up, restore, Platform Up, normal day-two |
| 7  | [Deployment View](07-deployment-view.md)                   | Infrastructure: Hetzner, network layout, regions              |
| 8  | [Crosscutting Concepts](08-crosscutting-concepts.md)       | Identity, secrets, observability, snapshots, idempotency      |
| 9  | [Architecture Decisions](09-architecture-decisions.md)     | Links to the ADR archive                                      |
| 10 | [Quality Requirements](10-quality-requirements.md)         | Concrete quality scenarios                                    |
| 11 | [Risks and Technical Debt](11-risks-and-technical-debt.md) | Known risks, current debt, mitigation plan                    |
| 12 | [Glossary](12-glossary.md)                                 | Terminology used here                                         |
