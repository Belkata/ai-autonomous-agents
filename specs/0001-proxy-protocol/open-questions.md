# 0001 — open questions

Deliberately undecided. Each one names what would settle it, so nobody has to reconstruct
the argument later.

## ~~Q1 — What is the cost of the resolvable-field allowlist? (`PRX-R-052`)~~ — resolved: sink-based

The allowlist closes the exfiltration path — write a handle into a readable field, read the
value back out of the resource you just created. The question was what shape the allowlist
takes in `0003`'s classifier table: per-action field paths (precise, but every action that
legitimately accepts a secret has to be enumerated before an agent can use one there, and the
failure mode is quiet — a table gap and a genuine attack both look like `handle_denied`) versus
a coarser allowlist of *sinks* — a Kubernetes Secret's `data`/`stringData`, connection-string-
shaped properties, and similarly-scoped write targets — checked by shape wherever they occur,
regardless of which action is writing to them.

**Resolved: sink-based.** Chosen specifically because it is the option that can be built before
any real usage exists. This question's own settling criterion — count how often resolution is
refused for a missing table entry versus a genuine exfiltration attempt, across the first ten
real tasks — can't produce that count under per-action paths without first doing the
enumeration work the count was supposed to justify. Sink-based gives up some precision (an
action could resolve a handle into an allowlisted shape for a purpose nobody anticipated) but
degrades gracefully — a new action writing to an already-allowlisted sink needs no table
change — and it still closes the concrete case this question worried about: a resource tag is
not one of the allowlisted shapes.

`PRX-R-056` (sensitive-read substitution) depends on the same table; the sink-based table
resolves that exposure the same way, by shape rather than by enumerating every sensitive
action.

**Revisit:** once real tasks run, tighten specific sinks toward per-action paths where the data
shows the coarse version is too permissive. That is a `0003` table change, not a `0001`
requirement change — `PRX-R-052` requires resolution only in "fields the action's classifier
entry marks resolvable" and is deliberately silent on the table's granularity, so nothing here
needs to reopen `0001`.

**No longer blocks** `0003` — the table format can be drafted against this.

## ~~Q2 — Is `error` distinguishable enough from `refused` in practice?~~ — resolved in v0.2.0

Resolved by `PRX-R-023`: `error` carries a `class` of `upstream`, `client` or `proxy`, chosen
so that each maps to a different correct response from the agent. An upstream 403 — the
proxy's own credential being under-scoped — is `class: proxy`, not retryable, and pages an
operator. Fixture: `examples/decision-error-proxy-underscoped.json`.

The review that shrank the refusal enum made this necessary rather than optional: once
malformed requests and classifier outages became errors rather than refusals, `retryable`
alone could no longer tell the agent whether to fix its request, back off, or stop.

## ~~Q3 — RFC 8785 implementation in Go~~ — resolved: real JCS via `gowebpki/jcs`

`PRX-R-041` cites JCS. The concern was that Go has no stdlib canonical JSON and that
third-party implementations vary in float handling — JCS numbers MUST serialise via the
ECMAScript `Number::toString` algorithm (the same one `JSON.stringify` uses), which is a
specific shortest-round-trip-decimal algorithm that Go's `strconv.FormatFloat` does not
reproduce byte-for-byte. The considered alternative was to stop citing JCS and instead
define the canonical form as a fixed Go struct serialised by a pinned encoder — viable
because the frozen object is proxy-constructed, never parsed from agent input, so nothing
requires JSON-general canonicalization, only self-consistency.

**Resolved: the premise doesn't hold up.** [`gowebpki/jcs`](https://github.com/gowebpki/jcs)
is a maintained Go library implementing RFC 8785 correctly, including ES6 number
serialisation, ported with permission from Anders Rundgren's own reference implementation
(Rundgren co-authored RFC 8785 and maintains the canonical multi-language conformance suite
at [`cyberphone/json-canonicalization`](https://pkg.go.dev/github.com/cyberphone/json-canonicalization)).
Unlike Rundgren's own Go port, `gowebpki/jcs` ships a tagged release and a real `go.mod`, so
it's consumable as a normal dependency. That removes the reason to consider the pinned-encoder
escape hatch: real JCS is available, and keeping it is worth it precisely for the case the
"Argument for keeping JCS" line named — the hash is verified by the approval card and the
audit log, and this is meant to become a multi-language, multi-proxy, eventually open-source
protocol, so byte-identical reproducibility outside this one Go codebase is a real property to
keep, not a hypothetical one.

**Caveat, and the precondition for shipping it:** `gowebpki/jcs` has low adoption (27 stars,
no release since October 2023) for something that becomes security-load-bearing — it decides
what an approver's signature actually binds to. Low adoption means fewer people have found
edge-case bugs, even though a small, spec-frozen serializer not changing in three years isn't
itself a red flag. Before `PRX-R-041` is implemented against it: run `gowebpki/jcs` against
Rundgren's published JCS numeric conformance test vectors (the same suite used to cross-check
JCS implementations across languages) and keep that check in CI, not just as a one-time
before-`accepted` gate. Current fixtures don't exercise this at all — `frozen-object.json` has
no numeric fields, which is exactly why `examples/README.md` already flags that its
regeneration one-liner is only a JCS *subset*, correct for fixtures with no floats. Add a
fixture with a numeric `parameters` field once the classifier (`0003`) makes one available, so
the float path has a golden test rather than only a library-level conformance check.

**No longer open.** `PRX-R-041`'s text is unchanged — this confirms the existing MUST is
implementable, it doesn't relax it.

## ~~Q4 — Where does the idempotency cache live, and for how long?~~ — resolved: in-memory is fine

`PRX-R-013` requires replay to be safe within a Warrant, and Warrants are short (4h). A
per-Warrant in-memory cache is trivial and dies with the run — but `PRX-R-040` already
requires the frozen store to survive proxy restart, so there is a durable store anyway. The
original worry: if the idempotency cache is memory-only and the proxy restarts between
executing a request and a retry arriving, the retry looks brand new and the upstream call
could fire twice — exactly the failure the receipt-number mechanism exists to prevent, and
exactly the kind of race an adversarial agent (per §3's trust model) would want to be running
during.

**Resolved: in-memory, no shared store needed — because that failure mode doesn't reach a
mutation.** Every `destructive`, `costsMoney`, or `dataActions` action is gated (`PRX-R-012`),
never immediately `executed`; a gated request's actual once-only guarantee comes from the
frozen-request store, not the idempotency cache — `PRX-R-040` already requires that store to
survive a restart, and `PRX-R-045` already requires a `frozen_hash` to execute at most once,
enforced with an atomic claim. Those two requirements exist independently of `PRX-R-013` and
already cover every create, update, and delete: they're all gated by construction, so they
were never depending on the idempotency cache for restart safety in the first place.

What `PRX-R-013` actually governs is the immediate-`executed` path — plain reads that aren't
destructive, costly, or a sensitive read. Losing that cache to a restart means a replayed read
runs again instead of returning the cached copy: a redundant upstream call and an extra audit
line, not a double mutation. Low enough stakes that an in-memory, per-Warrant cache is the
right amount of engineering — `PRX-R-013` is written to allow exactly this.

**No longer blocks anything.** `PRX-R-040`'s durability requirement, which does the real work
here, was already settled and unaffected by this resolution either way.

## ~~Q5 — Does the agent get to see the `preview`?~~ — resolved: full visibility

`decision-pending.json` carries a what-if diff and a cost figure. Showing it to the agent
makes it a better collaborator — it can spot that the plan deletes something and withdraw
before a human ever reviews the card. Showing it also hands a reconnaissance tool to an
adversary that can call `pending` freely, and `dry_run_hint` makes that cheap.

The schema had already answered this by omission: `preview` sat unqualified inside `pending`,
the object `0001` returns synchronously to the agent, while `design-note.md` (§06's flow
diagram, §07's "never put a command on the approval card" passage) only ever discussed the
diff as approval-card content. Neither document argued for the contradiction; it existed
because nobody had picked a side yet.

**Resolved: full visibility.** `PRX-R-048` now makes `preview` mandatory on every `pending`
decision, explicitly returned to the agent, not only the approval channel — a run that's about
to do something destructive or expensive should be able to recognize that and withdraw itself,
rather than always burning a human review cycle on mistakes it could have caught on its own.

This closes the question but not the risk it named: full visibility is exactly what turns
`dry_run_hint` into a free-diff request. `PRX-R-015` rate-limits `dry_run_hint` per
`(run identity, target)` as the direct consequence, reported as ordinary proxy-side throttling
(`class: upstream`, retryable) rather than a new refusal code. `design-note.md` §06–07 and
`CLAUDE.md`'s "Approve a diff, never a command" are updated in the same change so neither
quietly keeps describing the diff as card-only.

## ~~Q6 — Aggregate thresholds: what does "act on breach" mean?~~ — resolved: notify, for now (`PRX-R-071`)

The Warrant's `anomaly` block sets thresholds; the spec said the proxy must act, without
saying whether that's notify, pause the run, or refuse further reads. Refusing reads mid-run
is the only option that actually stops an exfiltration in progress, and also the only one that
can wreck a legitimate run at minute 40 of 45. Pausing needs a pause/resume mechanism that
doesn't exist yet — that's `0004`'s job, not `0001`'s.

**Resolved: notify only, for this version.** A breach emits one anomaly-breach observation to
the run's operator; nothing is refused, delayed, or paused because of it. This was already the
leaning here — it's now the actual text of `PRX-R-071` rather than an implied default, so the
requirement is something you can write a test against today instead of "the configured action."

**Note for later — pause on breach.** Notify-only means an aggregate breach — a run touching
far more of the ring than its own guide expects, for instance — can't actually be stopped
mid-flight; a human has to notice the alert and intervene by some other means. Once `0004`
gives escalations a real pause/resume mechanism (checkpoint the run, hold its namespace and
credentials without releasing them, resume from the same point), the same mechanism is a
natural fit for anomaly breaches too: pause the run the moment a threshold trips, page an
operator, and let them decide resume vs. terminate, rather than only ever notifying after the
fact. Worth scoping as a `0004` requirement when that spec is written, not assumed into `0001`
now — `0004` needs to define what "resume" means for a paused-on-breach run before this is
buildable (does it resume where it left off with the same Warrant, or does resuming require a
fresh revision, given the whole point was that something looked wrong?).

## Q7 — Should `out_of_ring` be a refusal at all, or a `pending`?

Raised by the v0.2.0 review. After the enum shrank, `out_of_ring` is the one remaining
refusal that is *escalatable* — and escalation is shaped almost identically to a gated
mutation: file a request, park the run, resume when a human answers. The only real difference
is what happens on approval. A `pending` executes the frozen request itself; an escalation
revises the Warrant and the agent retries.

**Argument for merging:** two protocol outcomes for one interaction shape is surface the
agent has to learn twice, and `0004` has to model the wait once anyway.

**Argument for keeping them apart:** the required agent behaviour differs. Never retry a
`pending` — the proxy will execute it. *Do* retry after an escalation resumes. Getting that
backwards means either a duplicated mutation or a stalled run.

**Settles it:** whether the difference can live in a field (`pending.kind: approval |
escalation`) without agents getting it wrong. That is really a question about `0004`'s
resume semantics, so it should be decided there and back-ported here rather than guessed now.

**Blocks:** nothing yet. `0001` can be accepted with `out_of_ring` as a refusal and changed
in a minor version if `0004` argues otherwise.

## Q8 — Should a `source: "none"` `preview` be allowed to reach `pending` at all?

`PRX-R-048` (Q5's resolution) made `preview` mandatory on every `pending` decision, with
`source: "none"` as the fallback "when neither exists for the action." The schema's `source`
enum is `az-what-if | terraform-plan | kubectl-dry-run | none` — there is no AWS-native value.
CloudFormation change sets only cover CloudFormation-managed resources, and the per-API
`DryRun` flag a few AWS services accept checks permissions, not producing a diff, so a direct
(non-IaC) AWS mutation has nothing to compute a real preview from. `terraform-plan` already
covers AWS resources managed through Terraform/OpenTofu — the gap is specifically imperative
AWS API calls outside IaC.

`PRX-R-048` and `PRX-R-015` answered *whether the agent sees the preview* and *how showing it
is rate-limited*; they didn't address what should happen when there is structurally nothing to
show. Today the schema lets `source: "none"` satisfy the requirement for *any* gated AWS
action, including a destructive or costly one — which means the one case the what-if/diff
mechanism exists to protect against (a tired approver clicking yes on a description-free card)
is exactly the case AWS-outside-IaC produces by default.

**Options:** (a) `0003`'s classifier table scopes AWS mutations to IaC-fronted actions only,
so every gated AWS action has a real `terraform-plan` preview and `source: "none"` never fires
for anything gated — direct AWS mutation outside that path is refused categorically, not
gated; (b) accept `source: "none"` as a legitimate `pending` outcome and rely on the raw
request `parameters` (already visible to the approver as the frozen request) standing in for
a diff; (c) build per-service preview shims for the highest-traffic destructive AWS actions,
falling back to (a)'s refusal for anything not covered.

**Leaning:** (a). It reuses `0003`'s existing Infracost-via-Terraform path rather than adding
a new one, and it keeps "the card carries a diff" true without exception rather than quietly
true except on one provider. (c) is real, open-ended work with no guarantee of covering the
actions that matter most.

**Settles it:** this is a `0003` classifier-table design call, not a `PRX-R-048` requirement
change — the requirement is satisfied either way. Decide when `0003` is drafted, since it
determines whether AWS gets `dataActions`-equivalent entries for imperative calls at all.

**Blocks:** nothing in `0001`. Blocks `0005` (approval-binding) from being specified
correctly for AWS until decided — see `specs/ROADMAP.md`.

## Q9 — Build the proxy's own credential layer, or adapt something that already exists?

`PRX-R-001` settles how the *agent* authenticates to the proxy (SPIFFE mTLS, SPIRE-issued
SVID). It says nothing about how the *proxy* then authenticates to Azure, AWS, the
Kubernetes API, and GitHub — obtaining, scoping, and rotating the credentials `PRX-R-060`'s
audit trail assumes it already holds. That's deliberately out of `0001`'s scope (§2: this
spec covers the agent↔proxy wire contract, not what the proxy does upstream), but it's a
real implementation decision with two candidates worth naming before it gets built from zero.

**Infisical Agent Vault** (MIT, self-contained, no Infisical platform dependency) is a
working, open-source HTTP credential proxy — attaches real credentials to outbound requests
at the network boundary so the caller never sees them. Close in shape to what the proxy needs
to do for the agent, though it has no notion of provider-action classification, dry-run
diffs, or cost — that stays this project's own layer regardless of which substrate sits under
it.

**Rossoctl (formerly Kagenti)'s `authbridge`** does the specific piece `PRX-R-001` names but
doesn't detail how to build: an Envoy `ext_proc` sidecar that exchanges a SPIRE-issued SVID
for a scoped OAuth2 token via Keycloak (RFC 8693 token exchange), so the workload holding the
SVID never holds the resulting credential either. Same SPIRE dependency already chosen,
applied to exactly the SVID-to-token-exchange step this design needs without specifying how.

**Options:** (a) build the token-exchange/credential-holding layer from scratch, informed by
reading both; (b) adopt Infisical Agent Vault as the outbound credential-injection layer and
build the classification/diff/cost logic (`0003`, `PRX-R-048`) as a layer in front of it;
(c) adopt Rossoctl's SVID-to-Keycloak-token-exchange pattern specifically for the
SPIRE-to-upstream-credential step, building everything else fresh.

**Leaning:** try (b) first — Infisical Agent Vault is standalone (single binary, SQLite, no
Keycloak/Postgres/UI to stand up) and closer to zero-spend-in-one-afternoon than adding
Rossoctl's dependency stack. If it doesn't fit the multi-provider (Azure/AWS/k8s/GitHub)
shape `PRX-R-010`'s `provider` field implies, that's a fast no.

**Settles it:** a week of hands-on evaluation against the k3d setup, not more research.
Neither project's docs say enough from the outside to decide this without running it.

**Blocks:** nothing in `0001` — this is an implementation question for whoever builds the
proxy binary, not a wire-contract question. Worth deciding before real implementation work
starts on the proxy, since it changes what gets built versus adopted. See
`docs/kagenti-rossoctl-evaluation-2026-08.md` and `docs/competitive-landscape-2026-08.md`.
