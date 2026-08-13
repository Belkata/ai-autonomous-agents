# Specs

Normative behaviour for this project. If code and spec disagree, one of them is a bug —
and which one is a decision someone has to make deliberately.

## Two artifacts, two jobs

| | Design doc (published artifact) | Specs (this directory) |
|---|---|---|
| Answers | *why* it is this way | *what* it does, observably |
| Audience | someone deciding whether the design is sound | someone implementing or reviewing a component |
| Lives | one stable URL, narrative prose | git, versioned alongside the code |
| Changes | when a decision changes | when behaviour changes |

Specs **link to** rationale; they do not restate it. When writing a spec forces a decision
to change, update `CLAUDE.md` and the design doc in the same commit — a spec that quietly
contradicts a settled decision is how the settled decisions stop being settled.

## Unit of specification

A **wire boundary**, not a user story. Spec the thing two components have to agree on:
the refusal envelope, the `Warrant` schema, what the classifier says about an action it has
never seen. Those are where being wrong is expensive.

Do not spec the whole system up front. Spec what you are about to build plus its immediate
contract neighbours, build it, then let what you learned correct the next spec. A complete
up-front spec set is waterfall with better tooling.

## Layout

```
specs/
  README.md                  # this file — the method, itself normative
  ROADMAP.md                 # spec sequence and why it is in that order
  NNNN-slug/
    spec.md                  # requirements with stable IDs
    schema/*.schema.json     # normative data shapes
    examples/*.json          # golden fixtures, referenced by requirement ID
    open-questions.md        # what we deliberately did not decide yet
```

Directory numbers are allocated once and never reused, even if a spec is withdrawn.

## Writing a spec

`spec.md` has these sections, in this order:

1. **Status** — `draft` | `accepted` | `implemented` | `superseded by NNNN`, plus a version.
2. **Scope** — one paragraph.
3. **Non-goals** — explicit. Every non-goal you leave out gets re-litigated by a contributor
   in six months.
4. **Actors and trust boundaries** — every spec here is a security control. Name the
   adversary. A spec that does not name its adversary cannot be reviewed.
5. **Requirements** — numbered, see below.
6. **Data shapes** — link to `schema/`. The schema is normative; prose about the schema is not.
7. **Failure modes** — what the component does when things go wrong, as first-class behaviour.
8. **Open questions** — link to `open-questions.md`.

### Requirements

Each requirement gets a **stable ID** — `PREFIX-R-NNN`, allocated in order, never reused,
never renumbered. Requirements use RFC 2119 keywords. Every requirement carries an
`*Accept:*` line: a concrete, observable condition, not a restatement of the requirement.

```markdown
#### PRX-R-012 — Unknown actions fail closed

The proxy MUST classify any action absent from the classifier table as simultaneously
`destructive`, `costsMoney` and `dataActions`.

*Accept:* a request for `Microsoft.Nonexistent/foo/bar` returns `pending` or `refused`,
never `executed`.
```

Prefer schemas and fixtures over prose. For the deterministic components — the action
classifier, the CI hygiene scan — the executable form of the spec is a **conformance
corpus**: a versioned input set with expected outputs. That option exists because those
components were deliberately built without an LLM in them; use it.

### The traceability rule

Every `MUST` requires at least one test whose name contains its ID.
`tools/spec-trace/spec_trace.py` enforces this and runs in CI.

```
uv run tools/spec-trace/spec_trace.py
```

This is the whole payoff of working this way. Without it these files become archaeology
within two months.

## Lifecycle

- `draft` — being written or argued about. No implementation should depend on it.
- `accepted` — frozen enough to build against. Changes bump the version and get a changelog
  entry at the bottom of `spec.md`.
- `implemented` — every `MUST` has a passing test carrying its ID.

Changing an `accepted` requirement's meaning means a **new ID**, with the old one marked
`withdrawn in vN`. Never silently redefine an ID that a test or a commit message points at.
