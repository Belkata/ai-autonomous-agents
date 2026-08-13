# AI Autonomous Agents — platform for gated agent workflows

## What this is

A control plane that lets AI agents do platform/infra work — take a task, write code,
open PRs, touch infrastructure — without ever holding a credential, and with a human
gate on anything destructive or costly.

Two goals, in order: something useful internally at the user's company, then an
open-source project. The user is a platform engineer. Target environment is
multi-cloud (Azure + AWS), Kubernetes, Microsoft Teams as the human interface.

**Full design doc — canonical copy is in the repo:** [`docs/design-note.md`](docs/design-note.md).

The published artifact at
https://claude.ai/code/artifact/9953c5cd-cb3c-4c89-aa4b-672c7e36f5bd is a *rendered view* of
that file, and it is **private** — external contributors cannot open it, so never link to it
as the primary reference. Edit the markdown first; if the artifact needs to match, republish
with `url:` set to that address so it updates in place instead of minting a new one.

Three artifacts, three jobs, and they must not drift into each other: `specs/` is normative
behaviour, `docs/design-note.md` is the rationale, this file is the settled decisions and the
working context. Where the note and a spec disagree, the spec wins and the note needs an
update.

## The flow

```
person chats with intake agent in Teams
  → agent interviews, reads repos + live infra (read-only)
  → one preview card, one signature
  → Jira ticket (for humans) + Warrant CR (for machines)
  → sandboxed coding agent runs, holding zero credentials
  → PR  |  approval card  |  escalation request
```

## Settled decisions — do not re-litigate these

Each of these was argued through and decided. The reasoning matters more than the
conclusion, so it's recorded.

**Credentials live in proxies, never in the agent.** The agent may run *any* command in
its sandbox. Every privileged action goes through a credential-holding proxy (MCP server
or HTTP proxy) that owns the token and executes the call itself. Consequence to plan for:
cloud audit logs show the proxy's identity, so the proxy's own log is the authoritative
"which run did what" record.

**Intercept at the API boundary, not the CLI.** Gating `az` is pointless — the agent will
write Python against `management.azure.com`. The sandbox's only network route is the proxy.

**One global policy for v1.** Not per-ticket. The Warrant carries intent, budget, TTL,
approvers, signature, and an advisory `guide`; a `GlobalPolicy` object does the enforcing.
Known weakness, deliberately accepted: global policy answers "is this dangerous?" but never
"is this expected here?", so every dangerous op goes to a human forever. That's fine at one
team, structurally limiting at ten. §05.1 of the doc keeps the door open — the fix is
selective auto-approval, needing per-agent trust and per-ticket expectation, and the
`guide` block exists to collect the evidence for writing those rules later.

**Classify by provider action name, not HTTP verb.** `Microsoft.Compute/virtualMachines/delete`,
`ec2:TerminateInstances`. ARM is POST-for-everything, so verbs tell you nothing. Azure's
`dataActions` flag is the sensitive-read axis.

**Approve a diff, never a command.** Run the provider's dry-run (`az deployment what-if`,
`terraform plan`, `kubectl --dry-run=server`) plus Infracost, and put *that* on the card.
Bind approval to a frozen (hashed) request the proxy then executes — never hand an approval
token back to the agent, or arguments change between approve and execute.

**Deny secrets, don't mask them.** Known-sensitive reads (Key Vault, storage keys, k8s
secrets, tfstate) are refused. Masking is only a backstop for the long tail. When the agent
needs a secret to *wire something up*, return a handle — `{{secret:kv-prod/db-password}}` —
that the proxy resolves at call time. Returning `****` just makes the agent loop.

**Scope guides reads; it does not bind PRs.** A PR changes nothing until merged, and the
repo's reviewers plus CODEOWNERS are already the correct gate. An agent that opens an
unexpected PR has produced a proposal that gets closed in ten seconds; an agent that *can't*
has produced a stalled run and a permission request that would have been approved anyway.
Reads inside the ring are free, drift is logged not blocked.

**Only two hard boundaries:** the ring (org / management group / cluster list) and the
never-list (IAM, prod).

**The agent always pushes to a fork.** This one is important and was decided against my
initial recommendation, correctly. The alternative — same-repo branches with provably
secretless workflows — fails on *verifiability*: an OIDC trust relationship lives on the
cloud side, in an Azure federated credential or AWS role trust policy naming the repo.
Scanning the repo cannot tell you which roles would accept a token, and the agent can add
the two lines that request one. Answering it properly means a fleet-wide, always-drifting
inventory of every federated credential in every subscription. **Prefer a control you can
verify locally and in constant time over one requiring a complete and current inventory.**
"Is this a fork PR?" is one field.

**Self-hosted runners are banned for anything an agent branch can trigger.** The fork closes
the credential problem, not the runner problem. This stays in policy, not in a scan.

**Three CI feedback loops, cheapest first.** (1) Verify in-sandbox, seconds, no credentials —
sandbox image must equal the runner image. (2) Real CI on the fork PR, rate-limited.
(3) A **scratch ring**: per-run namespace + resource group, TTL'd and cost-capped, where
mutations are *free and ungated* — apply, break, retry. Promotion to a real target is a PR.
Loop 3 is what makes "create a deployment for a new service" verifiable at all.

**Most of this system must never call an LLM.** The action classifier is a lookup table, the
CI hygiene scan is static analysis, the diff comes from the provider, the cost from Infracost.
Only the intake conversation and the coding loop need inference. Cheaper *and* deterministic,
testable, reviewable.

**The intake agent reads broadly, mutates nothing.** Its read ring may be *wider* than the
coding agent's (reading prod to write a good ticket is legitimate even when no coding agent
will touch prod); its mutation power is absent, not gated; it has exactly one write — create
issue. Neither agent's profile is a subset of the other's, which is the concrete argument for
per-agent policy eventually. Intake should read a **cached inventory**, not the live estate —
conversation latency budget is seconds.

**Zero spend.** No paid services while developing. See "Environment" below.

## Provisional names

`Warrant` (per-run), `GlobalPolicy`, `EscalationRequest`, `WarrantCeiling`. The metaphor is
worth keeping — a warrant is a signed, time-bound, scope-limited authorization. Schemas are
in §05 and §08 of the design doc.

## Architecture — build vs depend

**Depend on (do not rebuild):**
- kagent — k8s-native agent runtime, CRDs, BYO/A2A so OpenHands and LangGraph plug in
- agentgateway or IBM ContextForge — the data plane the proxies sit behind
- OpenHands — the coding agent (Agent Server, headless)
- kubernetes-sigs/agent-sandbox — Sandbox CRD, gVisor/Kata, warm pools (still pre-production)
- LangGraph — intake conversation + run state machine, for its durable checkpointer
- SPIRE — run identity; OpenBao — secret broker
- Argo CD / Atlantis-style plan-apply split for infra

**Write (this is the project):**
- `GlobalPolicy` / `Warrant` / `EscalationRequest` CRDs + controller
- the action classifier — provider action → destructive? costs money? sensitive read?
  (curated data, versioned; likely the project's moat)
- the what-if + cost approval card
- secret handles
- the escalation loop (structured refusal → request → approve → one-shot exception → resume)
- approval channel adapters (local CLI first, Teams second)
- the CI hygiene scan — **likely the OSS wedge**: standalone, useful immediately, needs none
  of the rest, and answers "where in our estate can agent-authored code reach a credential?"

## Environment — verified working on this machine

Arch Linux, kernel 7.1.8-zen1-3-zen. Docker 29.7.2 active, user in `docker` group.
(An earlier Docker failure was a stale running kernel after an upgrade — resolved by reboot.)

Installed and confirmed: `kubectl` 1.36.3, `helm` 4.2.2, `k9s`, `kind` 0.32.0, `k3d` (AUR),
`kustomize` 5.8.1, `gh` 2.97.0 (authed as **Belkata**, scopes: repo, workflow, gist, read:org),
`act` 0.2.89, `jq`, `go-yq`, `go` 1.26.5, `python` 3.14, `uv`, `az`, `aws`, `opa` 1.19.0,
`conftest`, `argocd` 3.4.2, `tofu` 1.12.1, `infracost`, `cloudflared`, `bao` (OpenBao) 2.6.1.

uv tools: `openhands` 1.16.0 (CLI), `litellm` 1.96.2, `localstack`, `aider-chat`.
Note the OpenHands PyPI split: `openhands` = CLI (pins Python 3.12), `openhands-sdk` /
`openhands-agent-server` 1.42.x = what the pipeline uses, `openhands-ai` 1.11 is the old
monolith with no entrypoints.

**Not installed, deliberately:** gvisor/`runsc` (plain runc is fine until the policy layer
works; `runtimeClassName` is a one-line change later), `k3s` (using k3d), `ollama` (add only
if local inference is wanted), `terraform` (using OpenTofu), SPIRE (belongs in-cluster via
Helm, not on the host).

**Not yet done:** no k3d cluster created. Git repo **is** initialised here (branch `main`),
with a **repo-local** identity `Belkata <belkata.okfo@gmail.com>` — `git config --global
user.name/user.email` are still unset by design. No remote yet.

## Free-tier notes

Public repos get unlimited hosted Actions minutes — use public repos for the prototype.
GitHub Issues behind a ticket adapter, Jira later. Azure Bot Service F0 is free with unlimited
messages on standard channels including Teams, but the M365 Developer Program E5 sandbox now
requires a Visual Studio Pro/Enterprise subscription — so either sideload into the company
tenant or build against the local approval adapter first. LocalStack for AWS shapes; Azure ARM
reads, resource-group/tag ops and `what-if` are free. Route all model calls through LiteLLM so
the model is config and free tiers can rotate.

## How we work: spec-driven

Specs are normative behaviour and live in `specs/`, versioned with the code. The design doc
artifact stays the *rationale* record. Specs link to rationale, never restate it. The method
is in `specs/README.md` and is itself normative — read it before writing or editing a spec.

The rule that makes it real: every `MUST` has a stable ID, every ID needs a test whose name
contains it, and `tools/spec-trace/spec_trace.py` fails CI when one doesn't. Draft specs are
advisory; `accepted` and `implemented` ones are enforced.

Spec one or two ahead of the code, never the whole system. Sequence and dependency edges are
in `specs/ROADMAP.md`.

## Settled since: language and first deliverable

**Language: Go for the controller and proxies, Python for the LangGraph intake agent.**
Confirmed. Go matches kubebuilder and the ecosystem being depended on.

**First spec is `0001-proxy-protocol`, not the CI hygiene scan.** The scan is the OSS wedge
and the fastest thing to ship, which is exactly why it doesn't need to be first — it has no
edges into anything else, so building it later invalidates nothing. The proxy protocol is
where every other component meets, so getting it wrong is a rewrite of all of them.

## Next steps

`specs/0001-proxy-protocol` is drafted — 37 requirements, JSON Schema, 12 golden fixtures.
Open before it can move to `accepted`: the six questions in its `open-questions.md`, of which
**Q1 (resolvable-field allowlist) blocks `0003`** because it changes the classifier entry
shape.

Then: `0002` (Warrant/GlobalPolicy objects) alongside `0003` (classifier), since the
classifier needs the ring and never-list shaped. `0004` can be stubbed — refuse terminally,
no escalation — until the loop runs end to end.

Zero-spend milestone to aim at: local approval adapter → GitHub Issue → OpenHands in a
sandbox on k3d → fork PR on a public repo → free Actions CI → scratch namespace it can break
freely → approval card → merge. Shortest spec path to a running loop is
**0001 → 0003 → 0005 → 0007**.

## Working with this user

Pushes back with good technical instincts and is usually right — several decisions above
started as my recommendation and were correctly overturned (fork-always, PRs-need-no-boundary,
global-policy-first). Argue the substance, don't defer reflexively, and don't re-open settled
ground. Prefers concrete mechanisms over surveys of options. Wants recommendations, not
menus.
