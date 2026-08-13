# 0001 — open questions

Deliberately undecided. Each one names what would settle it, so nobody has to reconstruct
the argument later.

## Q1 — What is the cost of the resolvable-field allowlist? (`PRX-R-052`)

The allowlist closes the exfiltration path — write a handle into a readable field, read the
value back out of the resource you just created. But it means the classifier table now
carries per-action field paths, not just three booleans, and every action that legitimately
accepts a secret has to be enumerated before an agent can use one there.

The failure mode is quiet: an agent hits `handle_denied` on a field that *should* have been
resolvable, and the run stalls on a table gap rather than a policy decision. `PRX-R-056`
widens the exposure — the read path now depends on the same table.

**Settles it:** run the first ten real tasks and count how often resolution is refused for
a missing table entry versus a genuine exfiltration attempt. If the ratio is bad, the
fallback is an allowlist of *sinks* (Kubernetes Secret data, connection-string properties)
rather than per-action field paths — coarser, still closes the tag case.

**Blocks:** `0003` (classifier entry shape). Decide before the table format freezes.

## ~~Q2 — Is `error` distinguishable enough from `refused` in practice?~~ — resolved in v0.2.0

Resolved by `PRX-R-023`: `error` carries a `class` of `upstream`, `client` or `proxy`, chosen
so that each maps to a different correct response from the agent. An upstream 403 — the
proxy's own credential being under-scoped — is `class: proxy`, not retryable, and pages an
operator. Fixture: `examples/decision-error-proxy-underscoped.json`.

The review that shrank the refusal enum made this necessary rather than optional: once
malformed requests and classifier outages became errors rather than refusals, `retryable`
alone could no longer tell the agent whether to fix its request, back off, or stop.

## Q3 — RFC 8785 implementation in Go

`PRX-R-041` cites JCS. Go has no stdlib canonical JSON and the third-party implementations
vary in float handling. Since the frozen object is constructed by the proxy — not parsed
from agent input — an alternative is to define the canonical form as a Go struct serialised
by a pinned encoder, sidestepping JCS entirely.

**Argument for keeping JCS:** the hash appears on an approval card and in an audit log that
may be verified by something that is not this proxy, possibly not in Go.

**Settles it:** whether anything outside the proxy ever needs to recompute the hash. If not,
a pinned encoder is simpler and the spec should say so instead of citing a standard nobody
implements.

## Q4 — Where does the idempotency cache live, and for how long?

`PRX-R-013` requires replay to be safe within a Warrant, and Warrants are short (4h). A
per-Warrant in-memory cache is trivial and dies with the run — but `PRX-R-040` already
requires the frozen store to survive proxy restart, so there is a durable store anyway.

**Settles it:** whether replay must survive proxy restart. Probably yes, in which case
idempotency and frozen requests share one store and this stops being a question.

## Q5 — Does the agent get to see the `preview`?

`decision-pending.json` carries a what-if diff and a cost figure. Showing it to the agent
makes it a better collaborator — it can spot that the plan deletes something and withdraw.
Showing it also hands a reconnaissance tool to an adversary that can call `pending` freely,
and `dry_run_hint` makes that cheap.

**Leaning:** return the diff, withhold nothing that the agent could not have computed from
resources it may already read, and rate-limit `dry_run_hint`. But this deserves a real
argument before it is written into `0005`.

## Q6 — Aggregate thresholds: what does "act on breach" mean? (`PRX-R-071`)

The Warrant's `anomaly` block sets thresholds; the spec says the proxy must act, and does
not say whether that is notify, pause the run, or refuse further reads. Refusing reads
mid-run is the only option that actually stops an exfiltration in progress, and also the
only one that can wreck a legitimate run at minute 40 of 45.

**Settles it:** `0004`, once pause/resume is real. Until then, notify.

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
