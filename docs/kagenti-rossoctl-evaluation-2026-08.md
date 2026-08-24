# Kagenti / Rossoctl — fork it, or borrow from it?

**Purpose:** `docs/competitive-landscape-2026-08.md` flagged Kagenti as the closest
Kubernetes-native analog found, and a naming risk against `kagent` (already a dependency).
This is the follow-up: cloned the repo, read the architecture docs, and answered the actual
question — fork it, or take specific ideas and move on. Not a spec; nothing here changes a
settled decision.

**Bottom line: don't fork it. Read `authbridge`, borrow the HITL vocabulary, and move on.**
The project has rebranded from Kagenti to **Rossoctl** (repo is still at
`github.com/kagenti/kagenti`, but the org, docs, and product name are now `rossoctl` /
rossoctl.dev — see naming note below) and it solves a different-shaped problem: agent-to-agent
and agent-to-tool authorization inside a mesh, not gating an agent's calls to cloud provider
APIs behind a human-approved diff and cost card. It's also a full platform — UI, Postgres-backed
backend, Keycloak, multi-agent orchestration, a skills/memory/knowledge-base layer — not a
library. Forking it means inheriting all of that for the sake of one mechanism worth having.

## What it actually is

Apache-2.0, actively developed (4,700+ commits, latest release `v0.6.1`, June 2026). Needs a
real Kubernetes cluster (16GB RAM / 4 cores minimum, tested on Kind and OpenShift/HyperShift).
Three parts: **RossoCortex** (a data-plane intercept between agents and everything external —
models, tools, users, other agents), a set of callable **services** (skills, tools, memory,
knowledge base, sandboxes), and **tooling** for observability/security/governance.

The identity stack is SPIFFE/SPIRE + Keycloak + OAuth2 token exchange (RFC 8693) — the same
SPIRE dependency already chosen for this project, applied to a different edge: every
agent-to-agent, agent-to-tool, and agent-to-MCP-server call gets intercepted, the caller's SVID
gets exchanged for an audience-scoped token, and the target validates it. It is *not* a gate on
calls to Azure, AWS, or the Kubernetes API server — it's internal mesh authorization.

## The one component worth reading closely: AuthBridge

`AuthBridge` (`github.com/rossoctl/cortex/tree/main/authbridge`) is an Envoy + Go
`ext_proc` sidecar that does, in a live, deployed implementation: validates an inbound JWT
against JWKS (401 on failure), and on the outbound side exchanges the caller's SPIFFE-derived
token for a target-audience token via Keycloak — the workload itself never holds or sees a
credential. This is the closest working analog found anywhere in this search to
`PRX-R-001`'s "credentials live in proxies, never in the agent," built on the exact identity
primitive (`SPIRE`) already in the dependency list. Worth reading as a reference for how the
token-exchange half of the proxy could be structured, even though the part that actually
matters for this project — classifying a *provider action* as destructive/costly/sensitive and
rendering a dry-run diff plus a cost number before a human signs it — has no equivalent here.
AuthBridge answers "is this caller allowed to reach this target," not "what will this specific
call do and what will it cost."

## The HITL ladder — steal the vocabulary, not the code

`docs/agentic-runtime/conversation-and-hitl.md` defines a four-level maturity model that's a
clean fit for the escalation loop's design doc:

| Level | What it means | Rossoctl's status |
|---|---|---|
| L0 — implicit deny | Policy blocks the action, agent gets an error | Implemented (OPA) |
| L1 — log and allow | Action proceeds, event logged for audit | Phase 2 |
| L2 — async review | Action proceeds, a human reviews after the fact | Phase 2 |
| L3 — sync approval | Action **blocks** until a human approves (proxy holds the request, gateway webhook, UI card) | **Phase 3 — not built**, blocked on upstream support for a `REVIEW_REQUIRED` policy decision |

The useful finding here is negative: L3 — the level equivalent to "approve a diff, never a
command," where the proxy holds the request open until a human signs it — is explicitly not
implemented anywhere in Rossoctl yet, and they call out a real UI component
(`HitlApprovalCard`) that exists but isn't wired to a live hold-and-resume flow. That's good
news for this project's differentiation: even the closest analog hasn't shipped the mechanic
this design bets on. It also validates that this project's approach (LangGraph `interrupt()` for
the hold, a signed `Warrant` to resume) is a reasonable way to close that exact gap — Rossoctl's
own sandbox design doc (`docs/architecture/agent-sandbox.md`, capability C14) independently
lands on "LangGraph `interrupt()` + A2A `input_required` for human-in-the-loop gating" as their
planned mechanism too, which is a second, independent point of validation for the LangGraph
choice already made.

## Sandbox research — nothing new to depend on, one dead end confirmed

Rossoctl's own agent-sandbox design doc evaluated seven other open-source sandboxing projects
before settling on `kubernetes-sigs/agent-sandbox` as a direct dependency — the same one already
chosen here, so no new information there. One of the seven, `cgwalters/devaipod`, was listed as
having "concepts replicated" for credential isolation via an MCP proxy (agent never receives
tokens) — close enough in spirit to be worth a direct look. It isn't: cloning it shows the
README now reads "this project was a useful experiment, however the author has found it easier
in practice to just use separate isolated Unix users or other tools" — abandoned by its own
author in favor of `OpenShell`. Not a live dependency candidate.

## Naming note — this needs to be explicit in the design doc

There are now three similarly-named, easily-confused Kubernetes-native AI-agent projects in
adjacent communities:

- **`kagent`** (`kagent.dev`) — already a "depend on" in `CLAUDE.md`, a k8s-native agent
  runtime.
- **`kagenti`** (`github.com/kagenti/kagenti`) — the repo name, CNCF-sandbox-adjacent.
- **Rossoctl** (`rossoctl.dev`) — what the `kagenti` repo actually calls itself now,
  throughout its own docs and branding.

Any public-facing comparison (the eventual OSS announcement, the design doc's prior-art
section) should say "Rossoctl (repo: `kagenti/kagenti`)" on first mention and never just
"Kagenti" or "kagent" unqualified — the two are unrelated projects with confusingly similar
names solving adjacent problems, and a reader skimming will conflate them.

## What this changes, practically

- Don't fork Rossoctl. Read `authbridge`'s source when `0001`'s credential-holding proxy gets
  built, specifically for the SPIRE-SVID-to-scoped-token exchange pattern — that part of the
  problem is genuinely solved there and there's no reason to redesign it from zero.
- Adopt the L0–L3 vocabulary in the design doc's escalation section; it's a clean way to talk
  about the refusal envelope's maturity without inventing new terms.
- The finding that L3 (sync-hold-for-approval) is unbuilt everywhere surveyed, including here,
  is worth a line in `docs/design-note.md`'s rationale for why this is worth building at all.
