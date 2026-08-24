# Competitive landscape — does "scoped autonomy" already exist?

**Purpose:** broad external check on whether the system described in `README.md`, `CLAUDE.md`,
and `docs/design-note.md` — a control plane that lets AI agents do platform/infra work while
never holding a credential, with a human gate on anything destructive or costly — already
exists as a product or open-source project. This is research, not a spec; nothing here changes
a settled decision.

**Bottom line:** no project combines all of this system's pieces the way it does. Every
individual piece has at least one real analog — credential proxying, policy-as-code gating,
human-approval SDKs, PAM vendors extending into "agent identity" — and 2026 has been a land
rush in this space, so the space itself is validated, not empty. But the specific combination —
an action classifier keyed on *provider action name* producing a versioned `destructive` /
`costsMoney` / `dataActions` table, a dry-run diff **and cost estimate** frozen into a hashed
request before a human signs it, secret *handles* instead of masking, mandatory fork-PR
isolation for the coding agent, and a three-tier scratch-ring CI loop — isn't assembled
anywhere found. Two projects are close enough to name directly in the design doc: **Keycard**
(closest on the approval-gate + credential-brokering side) and **Kagenti** (closest on the
Kubernetes-native, SPIFFE/SPIRE, MCP-gateway side — and a real naming-collision risk against
`kagent`, which this project already depends on).

## Credential brokering — "credentials live in proxies, never in the agent"

This exact principle is the fastest-moving part of the market in 2026.

- **[Infisical Agent Proxy / Agent Vault](https://infisical.com/blog/agent-proxy)** — open
  source, 2,000+ GitHub stars within months, "millions of agent runs" claimed. Sits as a
  transparent MITM that attaches credentials at the network boundary; the agent never reads a
  secret value. This is the same shape as `PRX-R-001`'s proxy-holds-the-token model. What it
  does **not** have: an action classifier, dry-run diffs, cost estimates, or any concept of
  "destructive vs. costly vs. sensitive-read." It's a secretless HTTP relay for arbitrary
  services (GitHub, Slack, LLM providers, 30+ presets), not a provider-action-aware gate.
  [GitHub: Infisical/agent-vault](https://github.com/Infisical/agent-vault)

- **[Keycard](https://www.keycard.ai/)** — the closest single analog found. Issues short-lived,
  task-scoped tokens via an STS-style exchange (Keycard itself never touches the data), binds
  access to a composite identity (user + device + agent + task), and — notably — **already does
  the escalation pattern**: policy blocks a call like `project.delete` and routes it to a human
  approval step, with an audit trail mapping the action back to a human/machine identity pair.
  Integrations listed are GitHub, Linear, Datadog, Slack, Notion, Salesforce, Google, AWS,
  Postgres. What's unconfirmed from public docs: whether approval includes a provider-native
  dry-run diff and a cost number (vs. just the action name and target), and there's no
  Azure/Kubernetes coverage mentioned. Worth a closer look before `0003` — if its policy model
  already expresses "destructive" as a first-class attribute, that's worth knowing about even
  if the target surface differs.

- **[Auth0 for AI Agents — Asynchronous Authorization](https://auth0.com/ai/docs/async-authorization)**
  — CIBA-based push-notification approval: the agent requests authorization, the human gets a
  push with a short `bindingMessage` ("Do you want to buy 3 phones"), and the agent polls until
  approved or denied. This is a *general tool-calling* consent primitive, not infra-specific,
  and it's synchronous-ish (agent blocks and polls) rather than the ticket-and-resume pattern
  this project uses (`EscalationRequest` → the run picks back up hours later). No diff, no cost
  card.

- **[Teleport Agentic Identity Framework](https://goteleport.com/docs/agentic-identity-framework/)**
  (rolled out across 2026, alongside "LLM Proxy" and "Delegated Identity") — extends Teleport's
  existing Access Requests (JIT elevation with Slack/Teams approval, which has existed for
  years and is architecturally close to "approval channel adapter") to agent workloads: agents
  get ephemeral X.509 identities instead of static keys, plus discovery of unmanaged agents/MCP
  servers, budget/rate limiting, and audit trails. Multi-cloud (AWS, Azure, GCP) and Kubernetes
  are explicitly supported. What public docs don't show: a diff-preview or cost-estimate
  artifact on the approval card, or a classifier that distinguishes destructive from benign
  writes by provider action name — Teleport's approval unit has historically been *access to a
  resource*, not *a specific mutating call with a rendered diff*.

- **CyberArk Secure AI Agents**, **Britive**, and **Apono** (acquired by 1Password, June 2026)
  — established PAM/JIT-access vendors all shipped "AI agent identity" products in 2026. This is
  strong market validation that "agents shouldn't hold standing credentials" is now a
  recognized category, but these are enterprise identity platforms selling visibility and JIT
  elevation across an estate, not a provider-action classifier + diff-approval workflow bound to
  a coding-agent pipeline.
  [1Password/Apono](https://1password.com/press/2026/june/1password-acquires-apono),
  [CyberArk Secure AI Agents](https://www.cyberark.com/resources/product-insights-blog/cyberark-secure-ai-agents)

## Kubernetes-native agent control planes — closest architectural sibling

- **[Kagenti](https://kagenti.github.io/.github/)** — an incubation project building, in its
  own words, "a Kubernetes-based control plane for AI agents," with an Agent Identity and
  Authorization Guard doing delegated access control via **SPIFFE/SPIRE** (the same identity
  primitive `CLAUDE.md` names as a dependency), a token-exchange + vault-secret-retrieval model
  so agents don't hold credentials, and an MCP Gateway for policy enforcement — all as
  Kubernetes CRDs. This is the single closest match found to the *infrastructure* half of the
  design (identity, credential brokering, k8s-native), short of the diff/cost approval card and
  the action-classifier taxonomy, which don't appear in what's public. The name is close enough
  to **`kagent`** (already a "depend on" in `CLAUDE.md`) that this is worth a direct check —
  worst case, they're unrelated projects with confusingly similar names in the same ecosystem
  and every mention needs to be unambiguous; best case, Kagenti is doing adjacent work worth
  building on rather than around.

- **[InfoQ: Building a Least-Privilege AI Agent Gateway for Infrastructure Automation with MCP,
  OPA, and Ephemeral Runners](https://www.infoq.com/articles/building-ai-agent-gateway-mcp/)** —
  not a product, a reference-architecture article, and explicitly says so ("a reference
  implementation... rather than a production-hardened security platform"). Still worth reading:
  it independently arrives at "agents never touch infra APIs directly, OPA gates every request,
  mutations run in short-lived isolated environments," and blocks destructive Terraform plans by
  filename convention. That a blog post converges on roughly this shape without diff cards, cost
  estimates, or an action-classifier dataset is a signal that the *hard* part — the classifier
  table and the diff+cost approval card — really is where this project's differentiation sits,
  not the credential-proxy part, which keeps getting reinvented as the easy 80%.

## Approval-gate SDKs — general pattern, not infra-specific

- **[HumanLayer](https://www.ycombinator.com/launches/M8e-humanlayer-human-in-the-loop-for-ai-agents-and-beyond)**
  (YC-backed) — an SDK that wraps arbitrary tool calls with approval gates, audit trails, and
  escalation paths over Slack/email. General-purpose, framework-level, not aware of cloud
  provider semantics, no classifier, no dry-run.
- **MCP "elicitation"** — the Model Context Protocol itself gained a human-in-the-loop
  primitive (elicitation) at the protocol level in 2026. This is a building block other systems
  (including a future version of this one) could use for the "ask a human mid-call" moment, not
  a competing system.
- OpenAI Agents SDK and similar frameworks ship generic human-in-the-loop hooks with the same
  characteristics: useful primitive, no infra awareness, no classifier, no diff/cost rendering.

## What genuinely doesn't exist yet, as far as this search found

No project combines, in one system:

1. An action classifier keyed on **provider action name** (not HTTP verb) that outputs
   `destructive` / `costsMoney` / `dataActions` as a curated, versioned dataset — the closest
   things found (Keycard's policy attributes, AWS's own IAM access-level summaries, Azure's
   `dataActions` flag) are each one axis or one provider, never the three-axis table across
   multiple clouds that `CLAUDE.md` calls "likely the project's moat."
2. A **dry-run diff plus a cost number**, frozen into a hashed request, that a human signs once
   and the proxy — not the agent — executes. Every credential-brokering product found stops at
   "the agent can't see the secret"; none render a provider-native diff (`what-if` /
   `terraform plan` / `kubectl --dry-run=server`) *and* an Infracost-style cost estimate on the
   same approval card bound to a frozen request.
3. **Secret handles** (`{{secret:kv-prod/db-password}}`) resolved by the proxy at call time,
   as opposed to masking a value the agent already received. Masking-as-backstop is the norm
   everywhere else surveyed.
4. **Mandatory fork-PR isolation** for the coding agent specifically because an OIDC trust
   relationship is unverifiable by scanning the repo — this is a narrow, well-reasoned argument
   specific to GitHub Actions + cloud federated credentials, and nothing found makes this
   argument or enforces it as a first-class control.
5. A **three-tier CI feedback loop** ending in a cost-capped, TTL'd scratch ring where mutations
   are free and ungated — this "let it break something that doesn't matter, cheaply, before it
   proposes touching something that does" loop wasn't found described anywhere else.
6. A resumable **ticket + signed Warrant** escalation pattern, where a structured refusal
   becomes a human-facing ticket and the run resumes hours later from where it stopped, as
   opposed to the agent blocking synchronously (Auth0's CIBA poll) or the request simply being
   denied (most policy engines).

## What this means practically

- Nothing here says "stop" — the two years-long land rush toward "agents shouldn't hold
  credentials" and "gate destructive actions behind a human" (Infisical, Keycard, Teleport,
  CyberArk, Britive/Apono, Auth0, Kagenti, HumanLayer, MCP elicitation, plus the InfoQ reference
  architecture) confirms the *problem* is real and recognized, which de-risks the open-source
  bet — there's already a category, and a public audience primed to understand the pitch.
- It does mean the design doc's competitive-landscape section (if one gets written for the
  eventual OSS announcement) should name **Keycard** and **Kagenti** specifically, since they're
  close enough that "how is this different" will be the first question from anyone who's
  looked at this space.
- The classifier table and the diff+cost approval card remain the two things worth protecting
  as differentiation — everything else in the "write, this is the project" list in `CLAUDE.md`
  has at least a partial analog already shipping; those two don't.

## What this doesn't tell you

This is a snapshot of a market moving fast — 1Password/Apono, Teleport's Agentic Identity
Framework, and CyberArk's AWS Marketplace listing all landed within the past few months of this
writing. Re-check before publishing the OSS wedge (`CLAUDE.md`'s CI hygiene scan) and before
`0003`'s classifier work starts in earnest — a funded competitor could ship the exact
classifier-plus-diff-card combination in the gap between now and then.
