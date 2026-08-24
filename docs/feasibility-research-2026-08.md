# Feasibility research — the proxy protocol's gates and checks against real k8s / GitHub / Azure / AWS

**Purpose:** external check on whether `0001-proxy-protocol`, `CLAUDE.md`'s settled decisions, and
`docs/design-note.md` assume mechanisms that actually exist on the four target surfaces, before
more of the system gets built against them. This is research, not a spec — nothing here changes a
`MUST`, and none of it should be read as re-opening a settled decision. Where it touches one, it's
flagged as "worth a look," not a recommendation to reopen it.

**Bottom line:** every gate the design leans on maps onto a real, currently-shipping primitive on
at least one target platform — none of it is vaporware. The two things worth your attention are
not in the parts you've already stress-tested (the refusal envelope, freezing, handle
substitution); they're in the parts that are still assumptions: AWS has no generic dry-run, and
one of the "depend on, don't build" components (LangGraph's checkpointer) provides less durability
than its name implies.

## Kubernetes

`kubectl --dry-run=server` and the underlying `?dryRun=All` API server flag are GA, have been
since 1.19, and apply broadly across create/update/patch/delete for any resource whose admission
chain supports it — this is the right primitive for "approve a diff" on k8s objects and it's
solid. [Kubernetes blog: apiserver dry-run and kubectl diff](https://www.kubernetes.io/blog/2019/01/14/apiserver-dry-run-and-kubectl-diff/)

SPIFFE/SPIRE for run identity is a mature, widely-deployed zero-trust workload identity standard
with real production usage in Kubernetes; nothing found suggests it's the wrong choice or immature
for what §PRX-R-001 needs (SPIFFE mTLS, SVID via SPIRE).
[SPIFFE/SPIRE deep dive](https://dev.to/kanywst/spiffespire-deep-dive-a5p)

One thing worth a look, not a contradiction of anything settled: k8s has a native mechanism —
impersonation headers — that could in principle let the *k8s* audit log show the run's identity
rather than only the proxy's, unlike Azure/AWS where the proxy log really is the only attribution
record. It's not turnkey — a proxy issue against Pinniped shows the audit-correlation piece isn't
solved out of the box — so this doesn't change `PRX-R-061` (the proxy's own log stays
authoritative for consistency across all four providers), but if k8s audit fidelity ever matters
on its own, impersonation is the primitive to reach for.
[Simplify K8s access control using RBAC impersonation](https://www.cncf.io/blog/2020/09/17/simplify-kubernetes-resource-access-control-using-rbac-impersonation/),
[Pinniped: audit log backend for impersonation proxy](https://github.com/vmware/pinniped/issues/642)

Two "depend on, don't build" components are less finished than the reliance on them suggests —
`CLAUDE.md` already flags one of these, this confirms it and adds detail:

- `kubernetes-sigs/agent-sandbox` is genuinely **alpha API**. Suspend/resume, HPA integration,
  and OpenTelemetry are done; auto-suspend/resume, scale-to-zero, and a first-class router are
  still "planned," not built. Fine to build a prototype against; expect breaking API changes
  before it's something to depend on for the isolation guarantees the design leans on.
  [Roadmap](https://github.com/kubernetes-sigs/agent-sandbox/blob/main/roadmap.md)
- `kagent` is CNCF **Sandbox** stage, accepted May 2025 — about 15 months old as a CNCF project
  as of this writing. Functionally real, governance-wise still early.
  [CNCF: kagent](https://www.cncf.io/projects/kagent/)

## GitHub

Fork-PR isolation is exactly as strong as `CLAUDE.md` assumes. GitHub's own security guidance
confirms workflows triggered from fork PRs get a read-only `GITHUB_TOKEN` by default and secrets
are withheld — the fork boundary is real, not just a convention, provided the workflow doesn't use
`pull_request_target` (worth an explicit callout in the CI hygiene scan's finding taxonomy, since
that's the one construct that reintroduces exactly the exposure the fork-always decision is
designed to avoid). [GitHub: secure use reference](https://docs.github.com/en/actions/reference/security/secure-use)

The self-hosted-runner ban is not overcaution — it's GitHub's own stated position: *"Self-hosted
runners should almost never be used for public repositories on GitHub, because any user can open
pull requests against the repository and compromise the environment."* Anyone who can fork and PR
can reach the runner's secrets and token. This settled decision is as solid as it gets.

OIDC federated trust (an Azure federated credential or AWS role trust policy naming the repo) is a
real, standard mechanism on both clouds — see below. The "is this a fork PR" verifiability argument
in `CLAUDE.md` holds up: the trust relationship really does live cloud-side and really can't be
discovered by scanning the repo.

## Azure

ARM `what-if` is real, free, and does what the design assumes — but it has a documented noise
problem worth budgeting for. Microsoft runs a dedicated public tracker for false-positive diffs
(GET responses surfacing properties the template never touched, read back as phantom changes) and,
historically, for what-if silently missing deny-policy violations. Recommendation: don't put raw
`what-if` JSON on an approval card — plan for a noise-filtering pass first, or the first thing a
human approver learns is to stop reading the diff.
[Azure/arm-template-whatif](https://github.com/Azure/arm-template-whatif),
[Bicep what-if docs](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if)

`dataActions` vs `actions` in Azure RBAC role definitions is real and is exactly the primitive the
classifier's "sensitive read" axis needs — this part of the design maps cleanly onto something
Azure already ships, no gap here.
[Understand Azure role definitions](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions)

Federated credentials (workload identity federation) for GitHub Actions are real and match the
design note's claim precisely: the federated credential's subject claim encodes the repo and ref,
the trust lives on an App registration or managed identity, and nothing about it is discoverable
from the repo side. [Entra: create a trust relationship](https://github.com/MicrosoftDocs/entra-docs/blob/main/docs/workload-id/workload-identity-federation-create-trust.md)

## AWS

This is the one place the design is assuming a primitive that doesn't exist. Azure has ARM
`what-if` and Kubernetes has server-side dry-run — a generic "show me the diff before you do it"
for arbitrary API calls. **AWS has nothing equivalent.** CloudFormation change sets are the closest
analogue, but they only cover resources under CloudFormation's management — they don't preview an
arbitrary imperative AWS API call the way `what-if` previews an arbitrary ARM deployment. A handful
of individual APIs (mostly EC2) accept a `DryRun` boolean, but that only validates that the caller
*would be allowed* to make the call — it returns a permissions check, not a diff.
[CloudFormation change sets](https://blog.boltops.com/2017/04/07/a-simple-introduction-to-cloudformation-part-4-change-sets-dry-run-mode/)

Practical consequence: "approve a diff, never a command" is solid for Azure and k8s as designed,
but for AWS it only works cleanly if AWS-side mutation is routed through IaC (`tofu plan`/`terraform
plan`, which the project already prefers) rather than allowed as direct imperative API calls the
way Azure/k8s actions might be. If the classifier is ever going to let an agent make a direct,
non-IaC AWS mutation, the design doc doesn't yet say what goes on the approval card for that case —
worth a decision before `0003`'s AWS entries get written, not after.

Action classification is the second AWS-specific gap. AWS does publish a real, machine-readable
taxonomy — every IAM action carries an access level (`List`, `Read`, `Write`, `Tagging`,
`Permissions management`) in the Service Authorization Reference — but it only distinguishes read
from write. It says nothing about which writes are destructive versus benign, and nothing about
cost. Azure's `dataActions` flag gets you the sensitive-read axis for free; AWS's access levels get
you read/write for free and leave `destructive` and `costsMoney` entirely to manual curation. This
is consistent with `CLAUDE.md` calling the classifier table "likely the project's moat" — this
research confirms AWS is where that moat has to be widest.
[AWS access level summaries](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_understand-policy-summary-access-level-summaries.html)

AWS IAM role trust policies keyed to GitHub's OIDC provider, scoped by the `sts:AssumeRoleWithWebIdentity`
subject claim, work exactly as `CLAUDE.md` describes — this part of the fork-verification argument
holds on AWS as well as Azure. LocalStack for local AWS-shape development and Infracost for AWS
cost estimation are both real and current; no gap there.

## Core stack — dependency risk, one item at a time

| Component | Status found | Read |
|---|---|---|
| SPIRE | Mature, in production use for zero-trust workload identity | Safe to depend on |
| OpenBao | Active Vault fork under Linux Foundation-adjacent governance, real community | Safe to depend on |
| `gowebpki/jcs` | Low adoption (per your own `open-questions.md`: 27 stars, no release since Oct 2023) | Your existing mitigation (run against Rundgren's conformance vectors in CI) is the right call — nothing new surfaced that changes this |
| agentgateway | Real, active, Solo.io-backed, blog cadence continues into mid-2026 | Newer, fast-moving — pin versions |
| IBM ContextForge (`mcp-context-forge`) | 4.3k stars, currently 1.0.0-RC-3 | Near-GA, not yet stable-tagged |
| OpenHands Agent Server (headless) | Real, documented, actively maintained, separate `OpenHands-Server` repo | Safe to depend on for the headless coding-agent role |
| kagent | CNCF Sandbox, accepted May 2025 | Early-stage governance; functionally usable |
| `kubernetes-sigs/agent-sandbox` | Alpha API, several core features still "planned" | Matches your own "still pre-production" flag — confirmed, not new |
| LangGraph checkpointer | See below | **New finding — read this one** |

### LangGraph's checkpointer is not a crash-recovery system

`CLAUDE.md` names LangGraph "for its durable checkpointer" as the backbone of the intake
conversation and run state machine. The checkpointer does what it says — it persists state — but
independent analysis of the framework surfaces a gap worth knowing about before the intake agent's
reliability story leans on it: the open-source library has no built-in crash detection ("if your
process crashes, no one knows — there is no supervisor, no watchdog, no heartbeat"), no automatic
resumption (a human or an external system has to notice the failure and call resume with the right
`thread_id`), and no coordination against two processes resuming the same thread concurrently. It's
explicitly single-process — no distributed execution, no task queue.
[Why checkpoints aren't durable execution](https://www.diagrid.io/blog/checkpoints-are-not-durable-execution-why-langgraph-crewai-google-adk-and-others-fall-short-for-production-agent-workflows)

For a single local intake session this is probably fine — one proxy of truth, low concurrency,
exactly the "local approval adapter first" milestone already targets. But it means "durable
checkpointer" should be read as "state survives a restart," not "the system recovers from a crash
on its own." If the run state machine (intake agent's conversation, or the coding loop's own state)
ever needs actual crash recovery or runs concurrently, that's an external supervisor/watchdog layer
that isn't currently named as a dependency anywhere in the doc — worth deciding whether that's in
scope for v1 or explicitly deferred, the same way `0004`'s escalation loop is currently stubbed.

## What this doesn't tell you

This confirms the primitives exist; it says nothing about whether your classifier table, your
sink-based handle allowlist, or your never-list are drawn correctly — that's `0003` and real usage,
not something a feasibility pass over provider docs can settle. And it's a snapshot: what-if noise,
project maturity stages, and star counts move; treat the CNCF-stage and alpha-API findings as
worth re-checking before `0007` and `0008` actually get built, not as permanent facts.
