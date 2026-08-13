# 0001 — open questions

Deliberately undecided. Each one names what would settle it, so nobody has to reconstruct
the argument later.

## Q1 — What is the cost of the resolvable-field allowlist? (`PRX-R-052`)

The allowlist closes the exfiltration path — write a handle into a readable field, read the
value back out of the resource you just created. But it means the classifier table now
carries per-action field paths, not just three booleans, and every action that legitimately
accepts a secret has to be enumerated before an agent can use one there.

The failure mode is quiet: an agent hits `unresolvable_handle` on a field that *should* have
been resolvable, and the run stalls on a table gap rather than a policy decision.

**Settles it:** run the first ten real tasks and count how often resolution is refused for
a missing table entry versus a genuine exfiltration attempt. If the ratio is bad, the
fallback is an allowlist of *sinks* (Kubernetes Secret data, connection-string properties)
rather than per-action field paths — coarser, still closes the tag case.

**Blocks:** `0003` (classifier entry shape). Decide before the table format freezes.

## Q2 — Is `error` distinguishable enough from `refused` in practice?

`PRX-R-021` says they must never be conflated, but there is a third thing: allowed,
attempted, and failed *because* of a permission the proxy itself lacks. That is an operator
bug — the proxy's own credential is under-scoped — and it currently surfaces as
`error / upstream_status: 403`, which is exactly the shape the agent must not treat as a
policy statement.

**Settles it:** either a fourth-and-a-half code (`error / proxy_misconfigured`, retryable
false, paging an operator) or a rule that upstream 403s are always operator alerts. Leaning
toward the former.

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
