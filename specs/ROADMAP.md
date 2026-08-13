# Spec roadmap

Only `0001` is written. Everything below it is an allocated number and a one-line scope,
not a commitment to the contents. Numbers are allocated up front so that cross-references
from `0001` have somewhere to point; they are written one or two ahead of the code, never
all at once (see `README.md`, "Unit of specification").

## Dependency order

```
0001 proxy protocol ──┬── 0002 Warrant / GlobalPolicy  ──┬── 0004 escalation loop
                      │                                  │
                      ├── 0003 action classifier ────────┤
                      │                                  │
                      └── 0005 approval binding ─────────┘

0006 CI hygiene scan        (independent — no edges into anything above)
0007 sandbox contract       (independent of 0001's wire format, depends on 0002's ring)
0008 scratch ring           (depends on 0002, 0007)
0009 intake agent           (depends on 0002; consumes nothing from 0001)
```

## The specs

| # | Slug | Scope | Status |
|---|---|---|---|
| 0001 | `proxy-protocol` | Agent↔proxy request/decision envelope, structured refusal, frozen request, secret handles, audit record | **draft** |
| 0002 | `warrant-objects` | `Warrant`, `GlobalPolicy`, `WarrantCeiling` schemas; revision semantics; what the compiler renders | not written |
| 0003 | `action-classifier` | Provider action → `{destructive, costsMoney, dataActions}`. Table format, versioning, unknown-action rule, conformance corpus | not written |
| 0004 | `escalation` | `EscalationRequest` object, state machine, pause/resume, timeout auto-deny, ticket append | not written |
| 0005 | `approval-binding` | What an approval is bound to, staleness, single-use, channel-adapter contract (local CLI first) | not written |
| 0006 | `ci-hygiene-scan` | Static analysis of workflow/Argo/Atlantis config; finding taxonomy; conformance corpus of repos | not written |
| 0007 | `sandbox-contract` | The four hygiene invariants (no SA token, no IMDS, egress default-deny, worthless node identity) as checkable assertions | not written |
| 0008 | `scratch-ring` | Per-run namespace + resource group, ungated mutation, TTL, cost ceiling, teardown | not written |
| 0009 | `intake-agent` | Draft-first conversation contract, cached inventory interface, the single write, sign-off transaction | not written |

## Why 0001 first

The CI hygiene scan (`0006`) is the OSS wedge and the fastest thing to ship — which is
exactly why it does not need to go first. It has no edges into anything else, so building
it later invalidates nothing.

`0001` is the opposite: every other component compiles against it. Getting the refusal
envelope or the frozen-request binding wrong is a rewrite of the classifier, the escalation
loop, the approval adapter and the audit story. Spec-driven development pays off where
interfaces are shared, and this is the only place in the system where *all* of them meet.

It is also language-neutral — JSON Schema plus HTTP semantics — so writing it does not block
on scaffolding, and scaffolding does not block on it.

## Sequencing against the zero-spend milestone

The milestone in `CLAUDE.md` is: local approval adapter → GitHub Issue → OpenHands in a
sandbox on k3d → fork PR on a public repo → free Actions CI → scratch namespace → approval
card → merge.

Mapped to specs, the shortest path that produces a running loop is
**0001 → 0003 → 0005 → 0007**, with `0002` written alongside `0003` because the classifier
needs the ring and never-list to be shaped. `0004` can be stubbed (refuse terminally, no
escalation) until the rest of the loop runs end to end — the refusal envelope in `0001`
already reserves the field.
