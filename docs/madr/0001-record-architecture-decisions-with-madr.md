# 0001 — Record architecture decisions with MADR

- Status: accepted
- Date: 2026-05-19

## Context and Problem Statement

The project has accumulated several architecture decisions whose rationale only lives in PR descriptions, commit messages, and the `../005_architecture.md` narrative. New contributors need a fast way to find "why was it built this way?" without reading the whole history.

## Considered Options

- **No ADRs** — keep design rationale spread across long-form docs and PRs.
- **Plain-text "decision log"** — one rolling file with timestamped entries.
- **MADR** (Markdown ADR), minimal template — one file per decision under `docs/madr/`.
- **Nygard-style ADR** — predecessor of MADR; same idea, less structured.

## Decision Outcome

Use **MADR** (https://adr.github.io/madr/), minimal template, one file per decision under `docs/madr/NNNN-kebab-case-title.md`.

Rules:
- ID format: 4-digit, zero-padded, monotonically increasing. Never reused.
- Status: `proposed` → `accepted` → `superseded by 00NN` / `deprecated`. Never delete a file once accepted.
- Keep ADRs short. Capture the **decision and why**, not the full design — long-form context belongs in `../005_architecture.md` and the code.
- Cross-link with `[MADR-00NN](./00NN-…)` when one decision depends on or supersedes another.

## Consequences

- New decisions get a 5-minute write-up instead of being lost in commit history.
- ADRs are immutable once accepted — corrections happen by a new superseding ADR, not by editing.
- Trade-off: small process overhead per non-trivial decision. Trivial decisions still go in code comments.

## References

- MADR project: https://adr.github.io/madr/
- ADR pattern (Michael Nygard): https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions
