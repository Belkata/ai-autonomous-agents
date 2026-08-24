# 0001 — Proxy protocol

**Status:** draft · v0.5.0
**Prefix:** `PRX`
**Rationale:** design doc §03 (where credentials live), §06 (three exits), §07 (policy in practice).
Settled decisions this spec implements are recorded in `CLAUDE.md` — do not re-litigate them here.

## 1. Scope

The synchronous request/decision contract between a sandboxed agent and a credential proxy,
and the out-of-band binding by which a human approval causes a previously-gated request to
execute. Covers: authentication of the caller, the request envelope, the four decision
outcomes, the structure of a refusal, freezing and hash-binding a gated request, secret
handle resolution, and the audit record each decision produces.

One protocol, several proxies. The cloud proxy, git proxy, cluster proxy and secret broker
all speak it; they differ only in the `provider` values they accept and the upstream they
front.

## 2. Non-goals

- **Which actions are dangerous.** The classifier is `0003`. This spec says the proxy asks
  a classifier and what it does with each answer, never what the answer is.
- **The shape of `Warrant` / `GlobalPolicy`.** That is `0002`. Here they are inputs.
- **The escalation state machine.** `0004`. This spec defines only the field by which a
  refusal advertises that escalation is possible, and the identifier it carries.
- **How an approval is obtained from a human** — card rendering, Teams, routing, timeouts.
  `0005`. This spec defines what the approval must be bound to when it arrives.
- **Sandbox construction.** `0007`. This spec does NOT assume the proxy is the sandbox's only
  egress — that assumption was removed once it was measured to be false in practice
  (`HTTP_PROXY` is a client-side convention, not a boundary). What this spec relies on instead
  is narrower and actually true: **the sandbox holds no credential**, so a privileged call that
  bypasses the proxy has nothing to authenticate with. Gating is enforced by credential
  custody, not by network containment.
- **Transport-level concerns already solved elsewhere:** TLS versions, HTTP/2 vs HTTP/1.1,
  retry backoff. Use the ecosystem defaults.

## 3. Actors and trust boundaries

| Actor | Trusted? | Notes |
|---|---|---|
| **Agent** (in sandbox) | **No — this is the adversary** | May run any command, send arbitrary bytes, replay, race, forge any field it can reach, and is subject to prompt injection from content it reads. |
| **Proxy** | Yes | Holds real credentials for the whole ring. The crown jewels; this design concentrates risk here rather than removing it. How the proxy itself obtains and rotates those credentials is out of this spec's scope (§2) — build-vs-adapt options in `open-questions.md` Q9. |
| **Classifier** | Yes | Pure function, no network, no LLM (`0003`). |
| **Approver** | Yes, but distractible | Authorized out-of-band. Approves diffs, not commands. |
| **Upstream provider API** | Yes | Azure ARM, AWS, Kubernetes API, GitHub. |
| **Content the agent reads** | **No** | Resource tags, ConfigMaps, issue bodies, file contents. Far more people can write these than can write to a repo. |

**The adversary model in one sentence:** assume the agent is actively trying to reach a
credential, and that everything it sends is attacker-controlled. Nothing in this protocol
may be enforced by the agent's cooperation, its prompt, or its choice of client library.

## 4. Requirements

### 4.1 Identity and Warrant binding

#### PRX-R-001 — Every request is authenticated to a run identity

The proxy MUST authenticate each request to a run identity (SPIFFE mTLS, SVID issued by
SPIRE). There MUST be no unauthenticated code path, including health, metrics and error
handlers that reflect request content.

*Accept:* a request without a client certificate is closed at the TLS layer; no protocol
response is produced.

#### PRX-R-002 — The Warrant is resolved from the identity, never from the request

The proxy MUST derive the governing `Warrant` and `GlobalPolicy` from the authenticated run
identity. A `warrant`, `policy`, `run_id` or equivalent field in the request body MUST be
rejected as malformed rather than honoured or ignored.

*Accept:* a request containing `"warrant": "some-other-warrant"` returns
`error / class: client`; the audit record shows the identity-derived Warrant.

> An ignored field is worse than a rejected one: it silently teaches the agent that the field
> exists and might work somewhere else.

#### PRX-R-003 — Dead Warrants stop serving

Once a Warrant's TTL has elapsed or its budget is exhausted, the proxy MUST refuse all
requests bound to it with `reason_code: warrant_dead`, carrying which of the two conditions
fired. This applies to in-flight `pending` requests: they MUST NOT execute on later approval.

*Accept:* a `pending` request approved after its Warrant's TTL returns
`refused / warrant_dead` and never reaches upstream.

#### PRX-R-004 — Warrant revision is pinned per decision

Each decision MUST record the Warrant revision it was evaluated against. Approval of a
gated request is valid only against the revision recorded at freeze time (`PRX-R-044`).

*Accept:* the audit record for every decision contains a non-empty `warrant_revision`.

### 4.2 Request envelope

#### PRX-R-010 — Requests describe an action, not a transport call

A request MUST carry: `provider`, `action` (the provider's own action name), `target`
(provider-scoped resource identifier), `parameters` (object), and `idempotency_key`.
It MUST NOT carry credentials, tokens, a Warrant reference, an approval reference, or a
raw upstream URL for the proxy to forward blindly.

Schema: [`schema/request.schema.json`](schema/request.schema.json).

*Accept:* `examples/request-executed.json` validates; a request with an `authorization`
field fails schema validation and returns `error / class: client`.

#### PRX-R-011 — Classification ignores the HTTP verb

The proxy MUST classify on `(provider, action, target)` and MUST NOT use the HTTP method of
either the inbound request or the intended upstream call as a danger signal.

*Accept:* `Microsoft.Compute/virtualMachines/deallocate` (upstream POST) classifies as
destructive; a tag `PUT` does not.

#### PRX-R-012 — Unknown actions fail closed

An `action` absent from the classifier table MUST be treated as simultaneously
`destructive`, `costsMoney` and `dataActions`, and MUST additionally be recorded as an
`unclassified_action` observation for the classifier's backlog.

*Accept:* a request for `Microsoft.Nonexistent/foo/bar` inside the ring returns `pending`,
never `executed`; an `unclassified_action` observation is emitted.

#### PRX-R-013 — Idempotency keys are honoured within a Warrant

Two requests with the same `idempotency_key` under the same Warrant MUST yield the same
decision and, for `executed`, MUST NOT perform the upstream call twice. This cache MAY be
in-memory and MAY be lost on proxy restart: every `destructive`, `costsMoney`, or
`dataActions` action is gated (`pending`) rather than immediately `executed` (`PRX-R-012`),
and a gated request's once-only execution guarantee already comes from the frozen-request
store instead (`PRX-R-040` durability, `PRX-R-045` single-use), which is required to survive
a restart independently of this requirement. So the only case an in-memory `PRX-R-013` cache
can lose to a restart is a replayed, already-`executed` read — re-running a read is not a
double mutation, just a redundant upstream call.

*Accept:* replaying an `executed` request returns the cached result with
`replayed: true` and no second upstream call appears in the proxy's outbound log, for as long
as the cache entry survives; a replay after the in-memory cache is lost is permitted to run
the read again rather than being required to reproduce the original result.

#### PRX-R-014 — Request size and depth are bounded

The proxy MUST enforce a maximum request body size and a maximum `parameters` nesting depth,
and MUST reject violations with `error / class: client` before parsing further.

*Accept:* a 100 MB body and a 500-deep nested object are both refused without the proxy
allocating proportionally.

#### PRX-R-015 — `dry_run_hint` is rate-limited per run and target

`preview` — the provider dry-run diff plus cost estimate — is returned to the agent in full on
every `pending` decision (`PRX-R-048`), which makes `dry_run_hint: true` a way to ask for that
diff without committing to the request. The proxy MUST rate-limit `dry_run_hint: true`
requests per `(run identity, target)` pair, so repeated dry-run-only requests cannot be used to
enumerate diffs across the ring for free. A rate-limited request MUST be reported as
proxy-side throttling — `error / class: upstream`, `retryable: true`, carrying
`retry_after_seconds` — the same shape as upstream throttling (§6), since the agent's correct
response is identical either way.

*Accept:* the Nth `dry_run_hint: true` request against a given target inside the configured
window returns `error / class: upstream`, `retryable: true`, with a non-null
`retry_after_seconds`; no `preview` is computed for the throttled request and no additional
upstream what-if call is made beyond the configured rate.
`examples/decision-error-dry-run-throttled.json` demonstrates the shape.

### 4.3 Decision outcomes

#### PRX-R-020 — Exactly four outcomes

Every request that gets past TLS MUST produce exactly one of:

| `decision` | Meaning |
|---|---|
| `executed` | The proxy performed the call. Result attached. |
| `pending` | Allowed in principle, gated on a human. Not performed. |
| `refused` | The policy says no. Terminal for this request as written. |
| `error` | Something broke. Not a policy statement. |

*Accept:* the decision schema's `decision` field is a closed enum of exactly these four.

#### PRX-R-021 — `error` is never conflated with `refused`

`refused` is a policy statement: the proxy will not do this. `error` is everything else that
prevented the call. A policy denial MUST NOT be reported as `error`, and a fault MUST NOT be
reported as `refused`.

*Accept:* an upstream 500 yields `error`; a never-list match yields `refused`; no input
produces both semantics under one code.

> The agent must be able to distinguish "you may not" from "it broke". Conflate them and it
> will retry a denial forever, or give up on a transient fault.

#### PRX-R-022 — Every response carries a correlation id

Every decision MUST include a `correlation_id`, stable across the lifetime of a gated
request (`pending` → approval → `executed`), and present in the audit record.

*Accept:* the `correlation_id` returned with `pending` equals the one on the eventual
`executed` decision.

#### PRX-R-023 — Errors carry a class, because the right response differs

`error` MUST carry `class`, one of:

| `class` | Meaning | What the agent should do |
|---|---|---|
| `upstream` | The provider failed or throttled. | Honour `retryable` and `retry_after_seconds`. |
| `client` | The request was malformed, oversized, or carried a forbidden field. | Fix the request. Retrying it unchanged will fail identically. |
| `proxy` | The proxy or a dependency it needs is broken or misconfigured. | Stop. Not the agent's to fix; this pages an operator. |

`retryable` MUST be `false` for every `class: client` error.

*Accept:* a 100 MB body yields `client`; ARM returning 503 yields `upstream`; the classifier
being unreachable yields `proxy`; an upstream 403 — meaning the *proxy's* own credential is
under-scoped — yields `proxy` and raises an operator alert, never `refused`.

> This is the resolution of open question Q2. An upstream 403 looks like a permission
> statement and is nothing of the kind: it means the proxy is misconfigured, and telling the
> agent "you may not" would send it off to find another route to a call it was allowed to
> make.

### 4.4 Refusal structure

#### PRX-R-030 — Every outcome is a structured decision object

A refusal MUST carry `reason_code`, human- and model-readable `reason` prose, `subject` (what
specifically was refused), and an `escalation` object. More broadly, no path may return a
bare HTTP status, an empty body, or an HTML error page — including malformed input and
requests rejected before policy evaluation, which are `error / class: client`.

*Accept:* every path that produces a refusal or an error is covered by a fixture in
`examples/` that validates against `schema/decision.schema.json`.

> This is the single most important interface in the design. A bare 403 gives the model
> nothing to reason about and it will route around you.

#### PRX-R-031 — `reason_code` is a closed enum

`reason_code` MUST be one of exactly five values. Adding one is a spec version bump.

| `reason_code` | Escalatable | Meaning |
|---|---|---|
| `never_listed` | never | IAM, prod. A hard boundary; no approval within this Warrant can reach it. |
| `out_of_ring` | yes | Outside the ring. Needs a Warrant revision, not an approval. |
| `handle_denied` | no | A secret handle names something outside the ring, or a field that would expose the value. |
| `warrant_dead` | no | TTL elapsed or budget exhausted. Carries which. |
| `approval_expired` | no | The gated request's own `expires_at` passed unanswered (`PRX-R-046`). The Warrant may still be alive; only this request is dead. |

*Accept:* the schema enumerates exactly these five; an unknown code fails validation in CI.

> This enum was ten values in v0.1.0. Six of them were not policy statements: faults and
> client errors moved to `error` (`PRX-R-023`), the sensitive-read case became a transform
> rather than a denial (`PRX-R-055`), and two Warrant-death conditions merged. What is left
> is only the cases where the correct answer really is "the proxy will not do this."

#### PRX-R-032 — Refusals say what would make it work, when that is safe

`reason` MUST state which rule refused and what the agent could do differently, where such
an alternative exists (use the scratch ring; open a PR instead; request a handle).
For `out_of_ring` and `never_listed` it MUST NOT enumerate the ring or the never-list.

*Accept:* a `never_listed` refusal for a role assignment names the IaC-PR route; an
`out_of_ring` refusal names neither other subscriptions nor other clusters.

#### PRX-R-033 — Refusals do not leak beyond the request

A refusal MUST NOT disclose information the agent could not otherwise obtain — in particular
it MUST NOT confirm or deny the existence of a resource outside the ring, and MUST NOT
distinguish "no such secret" from "secret you may not read".

*Accept:* refusals for an existing and a non-existent out-of-ring resource are
byte-identical apart from `correlation_id` and the echoed `subject`.

#### PRX-R-034 — Refusals are deterministic

The same request under the same Warrant revision and policy version MUST produce the same
`reason_code`. Refusal MUST NOT depend on time, load, or ordering.

*Accept:* a request replayed 100 times returns one distinct `(reason_code, subject)` pair.

#### PRX-R-035 — Repeated refusals are counted and surfaced

The proxy MUST track repeated refusals of equivalent requests within a run and include
`repeat_count` in the refusal. At a configured threshold it MUST emit a loop observation
for the run's operator.

*Accept:* the fifth equivalent refusal carries `repeat_count: 5` and emits one observation.

#### PRX-R-036 — Escalatability is explicit

`escalation` MUST be either `{"escalatable": false, "why": "<prose>"}` or
`{"escalatable": true, "escalation_id": "<opaque>"}`. Absent the field, the agent cannot
tell a dead end from a queue.

*Accept:* a never-list refusal is `escalatable: false`; an out-of-ring read refusal is
`escalatable: true` with a non-empty id.

### 4.5 Freezing and approval binding

#### PRX-R-040 — Gated requests are frozen server-side

On `pending`, the proxy MUST canonicalize the fully-resolved upstream request object,
persist it, and compute `frozen_hash` over the canonical bytes. Persistence MUST survive
proxy restart.

*Accept:* the same logical request frozen twice yields the same `frozen_hash`; the object
is retrievable after a proxy restart.

#### PRX-R-041 — Canonicalization is RFC 8785 (JCS), hash is SHA-256

Canonical form MUST be RFC 8785 JSON Canonicalization Scheme; `frozen_hash` MUST be the
lowercase hex SHA-256 of the canonical UTF-8 bytes, prefixed `sha256:`.

*Accept:* the fixtures in `examples/` carry precomputed hashes; the implementation
reproduces them exactly.

#### PRX-R-042 — The proxy executes the persisted object

On approval, the proxy MUST execute the object it persisted. It MUST NOT accept a request
body at approval time, MUST NOT re-derive the upstream call from anything the agent supplies
after freezing, and MUST re-verify `frozen_hash` immediately before dispatch.

*Accept:* an approval carrying a modified request body is rejected as `client`; the
executed upstream call byte-matches the persisted object.

#### PRX-R-043 — No approval token ever reaches the agent

The only identifier returned to the agent for a gated request is an opaque `request_id`
that confers the right to **poll status only**. Presenting it MUST NOT cause execution.

*Accept:* every agent-facing operation on `request_id` is read-only; there is no endpoint
that executes on agent presentation of any credential.

#### PRX-R-044 — Approval binds to (frozen_hash, warrant_revision)

An approval MUST reference both, and MUST be rejected if the Warrant has been revised since
freeze or the hash does not match. That rejection is returned to the **approval channel**,
not to the agent — it is not an agent-facing decision code. The agent's request stays
`pending`, re-evaluated under the new revision, and either resolves without a human or
requires a fresh approval.

*Accept:* approving after a Warrant revision returns a rejection to the channel and no
upstream call; polling `request_id` still returns `pending`, never a refusal the agent has
no way to act on.

#### PRX-R-045 — Approvals are single-use

A `frozen_hash` MUST execute at most once, enforced with a single point of commitment (e.g.
an atomic claim on the frozen record) so a race between dispatch attempts cannot double-execute.
Any approval received for a `frozen_hash` that has already executed, or is concurrently being
dispatched, MUST be rejected. As with a stale-revision approval (`PRX-R-044`), that rejection
MUST go to the **approval channel**, never to the agent: it is not an agent-facing decision
code, the agent's request stays at whatever decision the first successful dispatch produced,
and `request_id` polling MUST NOT expose a second decision path for it.

*Accept:* concurrent approvals of the same frozen request result in exactly one upstream call
and one `executed` decision object; every approval attempt after the first receives a
rejection on the channel; polling `request_id` never surfaces more than one decision for a
single `frozen_hash`.

#### PRX-R-046 — Pending requests expire and release resources

Every `pending` request MUST carry an expiry. On expiry the proxy MUST transition it to
`refused / approval_expired`, mark the frozen object unusable, and release any resource held
on its behalf. This is distinct from `warrant_dead` (`PRX-R-003`): the Warrant may still be
alive and able to serve other requests when one gated request's own clock runs out.

*Accept:* an unanswered gated request transitions to `refused / approval_expired` at its
expiry without human action, the run's namespace and credentials are not held open by it, and
`examples/decision-refused-approval-expired.json` validates against
`schema/decision.schema.json`.

#### PRX-R-047 — The approver is authenticated independently of the card

The approver's identity MUST come from the verified channel identity and a live group
membership check, never from a field in the approval payload.

*Accept:* an approval payload asserting a different approver identity is rejected; the audit
record shows the channel-verified identity.

#### PRX-R-048 — `preview` is mandatory on `pending`, and reaches the agent

Every `pending` decision MUST include `preview`, computed the same way regardless of
recipient: the provider's own dry-run plus a cost estimate (`source: "none"` when neither
exists for the action, per the existing enum). It is returned to the agent as part of the
synchronous decision object, not only to the approval channel — full visibility, chosen so the
agent can recognize its own destructive or costly requests and withdraw before a human ever
reviews the card, rather than flying blind into every gate. `PRX-R-015` rate-limits
`dry_run_hint` specifically because this requirement makes the diff free to request.

*Accept:* `examples/decision-pending.json`'s `preview` is present and non-empty; the decision
schema requires `preview` on every `pending` object, and a `pending` decision omitting it
fails schema validation.

### 4.6 Secret handles

#### PRX-R-050 — Handle grammar

A handle MUST match `{{secret:<broker>/<path>[#<field>]}}` where `broker` and `path` match
`[A-Za-z0-9._/-]+` and `field` matches `[A-Za-z0-9._-]+`. The proxy MUST reject any other
handle-like string rather than attempting a lenient parse; `schema/request.schema.json`
carries the normative pattern.

*Accept:* `{{secret:kv-prod/db-password}}` and `{{secret:kv-prod/conn#password}}` parse;
`{{secret:../../etc/passwd}}` does not.

#### PRX-R-051 — Handles resolve outbound only

The proxy MUST resolve handles when constructing the upstream call, and MUST NOT return a
resolved value in any decision, result, error, audit record, or approval card. Cards and
audit records show the handle text.

*Accept:* no fixture, log line, or card body in the test suite contains a resolved value;
a redaction test asserts this over the whole response corpus.

#### PRX-R-052 — Handles resolve only in declared fields

Resolution MUST be permitted only in `parameters` fields the action's classifier entry marks
resolvable. A handle anywhere else MUST refuse with `handle_denied`.

*Accept:* a handle in a resource *tag* value is refused; a handle in a Secret's `data` field
resolves.

> This is the exfiltration path: without it the agent writes a handle into any field that
> can later be read back, and reads the value out of the resource it just created. The
> field allowlist is the control; see `open-questions.md` for what it costs.

#### PRX-R-053 — Unresolvable handles stop the call, never pass through

If a handle cannot be resolved, the proxy MUST NOT forward the literal handle text upstream.
Which outcome it returns depends on why:

- **Policy** — path outside the ring, unknown broker, a field that would expose the value:
  `refused / handle_denied`.
- **Syntax** — the handle does not match the grammar in `PRX-R-050`:
  `error / class: client`.
- **Broker unavailable** — `error / class: proxy`.

*Accept:* a handle for an out-of-ring vault returns `refused / handle_denied`; a malformed
handle returns `error / class: client`; neither produces an upstream call.

#### PRX-R-054 — Masking is a backstop and is logged

Entropy- and pattern-based masking applies only to read results outside the known-sensitive
set — the long tail that `PRX-R-055` cannot enumerate. Every mask emitted MUST be logged as
an observation, because a mask usually means the ring or the sensitive-field table is wrong.

*Accept:* a masked read produces exactly one mask observation carrying the action and target.

#### PRX-R-055 — Sensitive reads return handles, not refusals

A read of a known-sensitive resource MUST NOT be refused. The proxy MUST perform the read and
return the resource with every secret-valued field replaced by a handle that resolves to that
value, leaving structure and non-secret fields intact. The decision is `executed`, carrying
`handles_substituted` as a count.

*Accept:* `k8s:core/v1/secrets/read` on `checkout/checkout-db` returns
`{"data": {"username": "checkout_app", "password": "{{secret:k8s:checkout/checkout-db#password}}"}}`
— key names visible, no value anywhere in the response, audit record, or log.

> This replaces the v0.1.0 behaviour of refusing the read outright, which was strictly worse.
> A refusal tells the agent nothing about the shape of what exists, so it cannot tell a secret
> it must not read from one that is simply absent, and it cannot discover that the wiring it
> was asked to create is already there. Substitution gives it everything it legitimately needs
> — which keys exist, what is already connected — and still never yields a value. The same
> argument applies to `tfstate`, where the structure is the point and the secrets are
> incidental.
>
> The security property is unchanged, because it never rested on refusal: it rests on the
> proxy holding the credential and resolving handles outbound only (`PRX-R-051`), into fields
> that cannot echo them back (`PRX-R-052`).

#### PRX-R-056 — Substitution is driven by a table, and unknown shapes fail closed

Which fields of which resources are secret-valued MUST come from a versioned table, not from
inspection of the value. Where the proxy holds a known-sensitive action but no field entry
for the shape returned, it MUST fall back to refusing the read with `handle_denied` rather
than returning an unsubstituted body.

*Accept:* a Key Vault response shape absent from the table returns `refused / handle_denied`;
no response body reaches the agent.

### 4.7 Audit

#### PRX-R-060 — Every decision produces one audit record

All four outcomes, including `malformed` refusals and TLS-authenticated requests rejected
pre-policy, MUST append exactly one record containing: timestamp, run identity, Warrant ref
and revision, policy version, classifier table version, correlation id, provider, action,
target, decision, `reason_code`, `frozen_hash` where applicable, approver identity where
applicable, and upstream request id where one was returned.

*Accept:* decision count equals audit record count across the conformance run.

#### PRX-R-061 — The audit log is the authoritative attribution record

Because cloud audit logs show the proxy's identity rather than the run's, the proxy's log
MUST be append-only and tamper-evident, and MUST be durable before the upstream call is
dispatched — not after.

*Accept:* killing the proxy between audit write and dispatch leaves a record of an
attempted call; killing it before the audit write leaves no upstream call.

#### PRX-R-062 — Audit records carry no secret material

Records MUST NOT contain resolved handle values, denied read payloads, or masked content.

*Accept:* the redaction test in `PRX-R-051` covers audit output.

### 4.8 Drift and aggregates

#### PRX-R-070 — Drift is observed, never enforced

Reads and PRs outside the Warrant's `guide` but inside the ring MUST be permitted and
recorded as drift observations against the guide's `driftPolicy`.

*Accept:* a read of a repo absent from `expectedReads` but inside the org returns
`executed` and emits one drift observation.

#### PRX-R-071 — Aggregate thresholds are enforced independently of per-call decisions

The proxy MUST evaluate the Warrant's `anomaly` thresholds across the run and act on breach
even when every individual call was allowable. For this version, "act" MUST mean emitting
exactly one anomaly-breach observation to the run's operator — the same observation mechanism
already used for masks (`PRX-R-054`), unclassified actions (`PRX-R-012`), and repeat-refusal
loops (`PRX-R-035`). A breach MUST NOT refuse, delay, or pause any call: neither is
implementable yet, since both depend on the pause/resume state machine that `0004` owns and
that does not exist. Escalating a breach's response beyond notify — pausing the run, or
refusing further calls — is deferred to `0004`; see `open-questions.md` Q6.

*Accept:* a run reading `distinctRepos + 1` repos emits exactly one anomaly-breach observation
carrying the threshold and the actual count, while each read individually still returns
`executed` and the run is not paused or blocked because of it.

## 5. Data shapes

Normative:

- [`schema/request.schema.json`](schema/request.schema.json)
- [`schema/decision.schema.json`](schema/decision.schema.json)

Golden fixtures in [`examples/`](examples/), each referenced from the requirement it
demonstrates. Fixtures are part of the spec: changing one is a spec change.

## 6. Failure modes

| Failure | Behaviour |
|---|---|
| Classifier unavailable | `error / class: proxy` for everything mutating; reads inside the ring continue. Fail closed on the dangerous axis, not on the whole system. Not a refusal: the proxy cannot tell, which is different from saying no. |
| Audit sink unavailable | Stop dispatching, `error / class: proxy`. `PRX-R-061` makes the audit write a precondition, so the proxy degrades to erroring rather than acting unattributably. |
| Secret broker unavailable | `error / class: proxy`, retryable. A handle that *could* resolve but currently cannot is a fault, not a policy statement. |
| Sensitive-field table has no entry for a returned shape | `refused / handle_denied` per `PRX-R-056`. The one place the read path still refuses. |
| Approval channel unavailable | Requests still freeze and go `pending`; they expire normally per `PRX-R-046`. |
| Upstream throttling | `error / class: upstream`, retryable, with the upstream's retry hint. Proxy-side rate limiting is the same shape — the agent's response is identical, so it does not need a separate code. |

## 7. Open questions

See [`open-questions.md`](open-questions.md).

## Changelog

- **v0.5.0** — withdraws a false assumption rather than changing any requirement. Non-goals
  previously read "this spec assumes the sandbox's only egress is the proxy." Measured on the
  k3d prototype, that is not true and cannot be made true by the proxy alone: `HTTP_PROXY` is
  a client-side convention, and `curl --noproxy '*'` from the sandbox reached the internet
  directly. The spec's basis is now stated as credential custody — the sandbox holds no
  credential, so a call that bypasses the proxy has nothing to authenticate with — which is
  narrower, true, and sufficient for every requirement here. No requirement ID changed meaning,
  so this is a minor bump rather than major; see `docs/design-note.md` for the accepted risk
  that open egress carries.

- **v0.4.1** — resolves open questions Q4 and Q6. `PRX-R-013`'s idempotency cache may now be
  in-memory and restart-fragile; the once-only guarantee that actually matters for a mutation
  was never this requirement's to carry — `destructive`/`costsMoney`/`dataActions` actions are
  always gated, and their single execution is already covered by the frozen-request store's
  own restart durability (`PRX-R-040`, `PRX-R-045`). `PRX-R-013` was only ever load-bearing for
  the plain-read replay path, where losing the cache costs a redundant read, not a double
  mutation. `PRX-R-071`'s "act on breach" now names a concrete behavior — one observation to
  the operator, nothing paused or refused — instead of leaving "the configured action"
  undefined; pausing on breach is noted as a natural fit for `0004`'s pause/resume machinery
  once that exists, but is not specified here.

- **v0.4.0** — resolves open question Q5: the agent sees `preview` in full on every `pending`
  decision (`PRX-R-048`, now required rather than optional in the schema), not only the
  approval card — chosen so the agent can recognize and withdraw its own destructive or costly
  requests before a human reviews them. This makes `dry_run_hint` a way to request a diff for
  free, so `PRX-R-015` rate-limits it per `(run identity, target)`, reported as proxy-side
  throttling rather than a new error shape. `design-note.md` §06–07 previously described the
  diff as approval-card-only content and did not account for the agent also seeing it; both are
  updated to match.

- **v0.3.0** — closes two gaps found in review, both in the freezing/approval section.
  `PRX-R-046`'s expiry path had nowhere to land in the closed `reason_code` enum — a `pending`
  request timing out unanswered is a different event from its Warrant dying, and the enum only
  had room for the latter. Added `approval_expired` (`PRX-R-031`), now five values, with a
  fixture. `PRX-R-045` said a second approval "MUST be refused" without saying where that
  refusal surfaces; it now explicitly mirrors `PRX-R-044` — the approval channel, never the
  agent, since there is still no agent-facing code for "already executed."

- **v0.2.0** — the refusal surface halves. `reason_code` goes from ten values to four
  (`PRX-R-031`). Sensitive reads become handle substitution rather than denial
  (`PRX-R-055`, `PRX-R-056`), which is the change with real behavioural weight: the agent now
  learns the shape of what exists instead of hitting a wall. Faults and client errors move to
  `error`, which gains a `class` (`PRX-R-023`) and thereby resolves open question Q2.
  `stale_approval` turns out to be channel-facing and leaves the agent-facing enum entirely
  (`PRX-R-044`). Two Warrant-death conditions merge.

  Prompted by review: *"do we need a denial from the proxy? The only thing I can think of
  that could be denied is secrets, and we can return handles."* Mostly right — the answer is
  that denial survives for steering rather than for security, and the never-list is what
  makes it load-bearing. See issue #1.

- **v0.1.0** — initial draft.
