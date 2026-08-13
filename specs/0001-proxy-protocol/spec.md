# 0001 — Proxy protocol

**Status:** draft · v0.1.0
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
- **Sandbox construction.** `0007`. This spec assumes the sandbox's only egress is the proxy
  and does not restate why.
- **Transport-level concerns already solved elsewhere:** TLS versions, HTTP/2 vs HTTP/1.1,
  retry backoff. Use the ecosystem defaults.

## 3. Actors and trust boundaries

| Actor | Trusted? | Notes |
|---|---|---|
| **Agent** (in sandbox) | **No — this is the adversary** | May run any command, send arbitrary bytes, replay, race, forge any field it can reach, and is subject to prompt injection from content it reads. |
| **Proxy** | Yes | Holds real credentials for the whole ring. The crown jewels; this design concentrates risk here rather than removing it. |
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

*Accept:* a request containing `"warrant": "some-other-warrant"` returns `refused` with
`reason_code: malformed`; the audit record shows the identity-derived Warrant.

> An ignored field is worse than a rejected one: it silently teaches the agent that the field
> exists and might work somewhere else.

#### PRX-R-003 — Expired Warrants stop serving

Once a Warrant's TTL has elapsed, or its budget is exhausted, the proxy MUST refuse all
requests bound to it with `reason_code: warrant_expired` or `budget_exhausted`. This applies
to in-flight `pending` requests: they MUST NOT execute on later approval.

*Accept:* a `pending` request approved after its Warrant's TTL returns
`refused / warrant_expired` and never reaches upstream.

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
field fails schema validation and returns `refused / malformed`.

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
decision and, for `executed`, MUST NOT perform the upstream call twice.

*Accept:* replaying an `executed` request returns the cached result with
`replayed: true` and no second upstream call appears in the proxy's outbound log.

#### PRX-R-014 — Request size and depth are bounded

The proxy MUST enforce a maximum request body size and a maximum `parameters` nesting depth,
and MUST reject violations with `reason_code: malformed` before parsing further.

*Accept:* a 100 MB body and a 500-deep nested object are both refused without the proxy
allocating proportionally.

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

An upstream failure, timeout, or proxy-internal fault MUST return `decision: error` with an
`upstream_status` where one exists and a `retryable` boolean. It MUST NOT be reported as
`refused`, and a policy denial MUST NOT be reported as `error`.

*Accept:* an upstream 500 yields `error / retryable: true`; a never-list match yields
`refused`; no input produces both semantics under one code.

> The agent must be able to distinguish "you may not" from "it broke". Conflate them and it
> will retry a denial forever, or give up on a transient fault.

#### PRX-R-022 — Every response carries a correlation id

Every decision MUST include a `correlation_id`, stable across the lifetime of a gated
request (`pending` → approval → `executed`), and present in the audit record.

*Accept:* the `correlation_id` returned with `pending` equals the one on the eventual
`executed` decision.

### 4.4 Refusal structure

#### PRX-R-030 — Refusals are structured, always

A refusal MUST be a well-formed decision object containing `reason_code`, human- and
model-readable `reason` prose, `subject` (what specifically was refused), and an `escalation`
object. A bare HTTP status, an empty body, or an HTML error page MUST NOT occur — including
for malformed input and for requests rejected before policy evaluation.

*Accept:* every path that produces a refusal is covered by a fixture in `examples/` that
validates against `schema/decision.schema.json`.

> This is the single most important interface in the design. A bare 403 gives the model
> nothing to reason about and it will route around you.

#### PRX-R-031 — `reason_code` is a closed enum

`reason_code` MUST be one of: `out_of_ring`, `never_listed`, `sensitive_read`,
`unresolvable_handle`, `budget_exhausted`, `warrant_expired`, `rate_limited`,
`unclassified_action`, `stale_approval`, `malformed`. Adding a value is a spec version bump.

*Accept:* the schema enumerates exactly these; an unknown code fails validation in CI.

#### PRX-R-032 — Refusals say what would make it work, when that is safe

`reason` MUST state which rule refused and what the agent could do differently, where such
an alternative exists (use the scratch ring; open a PR instead; request a handle).
For `out_of_ring` and `never_listed` it MUST NOT enumerate the ring or the never-list.

*Accept:* a `sensitive_read` refusal for a Key Vault secret names the handle syntax; an
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

*Accept:* an approval carrying a modified request body is refused as `malformed`; the
executed upstream call byte-matches the persisted object.

#### PRX-R-043 — No approval token ever reaches the agent

The only identifier returned to the agent for a gated request is an opaque `request_id`
that confers the right to **poll status only**. Presenting it MUST NOT cause execution.

*Accept:* every agent-facing operation on `request_id` is read-only; there is no endpoint
that executes on agent presentation of any credential.

#### PRX-R-044 — Approval binds to (frozen_hash, warrant_revision)

An approval MUST reference both, and MUST be rejected as `stale_approval` if the Warrant has
been revised since freeze, or if the hash does not match.

*Accept:* approving after a Warrant revision returns `refused / stale_approval`; the request
must be re-frozen and re-approved.

#### PRX-R-045 — Approvals are single-use

A `frozen_hash` MUST execute at most once. A second approval or a second dispatch attempt
MUST be refused.

*Accept:* concurrent approvals of the same frozen request result in exactly one upstream
call.

#### PRX-R-046 — Pending requests expire and release resources

Every `pending` request MUST carry an expiry. On expiry the proxy MUST auto-deny, mark the
frozen object unusable, and release any resource held on its behalf.

*Accept:* an unanswered gated request transitions to `refused` at its expiry without human
action, and the run's namespace and credentials are not held open by it.

#### PRX-R-047 — The approver is authenticated independently of the card

The approver's identity MUST come from the verified channel identity and a live group
membership check, never from a field in the approval payload.

*Accept:* an approval payload asserting a different approver identity is rejected; the audit
record shows the channel-verified identity.

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
resolvable. A handle anywhere else MUST refuse with `unresolvable_handle`.

*Accept:* a handle in a resource *tag* value is refused; a handle in a Secret's `data` field
resolves.

> This is the exfiltration path: without it the agent writes a handle into any field that
> can later be read back, and reads the value out of the resource it just created. The
> field allowlist is the control; see `open-questions.md` for what it costs.

#### PRX-R-053 — Unresolvable handles refuse, never pass through

If a handle cannot be resolved — unknown broker, path outside the ring, policy denial,
malformed — the proxy MUST refuse. It MUST NOT forward the literal handle text upstream.

*Accept:* a handle for an out-of-ring vault returns `refused / unresolvable_handle`; the
upstream log shows no call.

#### PRX-R-054 — Masking is a backstop and is logged

Entropy- and pattern-based masking applies to read results outside the known-sensitive set.
Every mask emitted MUST be logged as an observation, because a mask usually means the ring
or the deny-list is wrong.

*Accept:* a masked read produces exactly one mask observation carrying the action and target.

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
even when every individual call was allowable.

*Accept:* a run reading `distinctRepos + 1` repos triggers the configured action while each
read individually returned `executed`.

## 5. Data shapes

Normative:

- [`schema/request.schema.json`](schema/request.schema.json)
- [`schema/decision.schema.json`](schema/decision.schema.json)

Golden fixtures in [`examples/`](examples/), each referenced from the requirement it
demonstrates. Fixtures are part of the spec: changing one is a spec change.

## 6. Failure modes

| Failure | Behaviour |
|---|---|
| Classifier unavailable | Refuse everything mutating with `unclassified_action`; reads inside the ring continue. Fail closed on the dangerous axis, not on the whole system. |
| Audit sink unavailable | Stop dispatching. `PRX-R-061` makes the audit write a precondition, so the proxy degrades to refusing rather than acting unattributably. |
| Secret broker unavailable | `unresolvable_handle`, escalatable false, retryable — this is an `error`-adjacent refusal and the fixture pins which. |
| Approval channel unavailable | Requests still freeze and go `pending`; they expire normally per `PRX-R-046`. |
| Upstream throttling | `error / retryable: true` with the upstream's retry hint, never `rate_limited` (which means *the proxy* limited it). |

## 7. Open questions

See [`open-questions.md`](open-questions.md).

## Changelog

- **v0.1.0** — initial draft.
