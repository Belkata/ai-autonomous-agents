# Fixtures

Part of the spec, not illustrations. Changing one is a spec change; `tools/spec-trace`
validates them against `../schema/` on every run.

| Fixture | Demonstrates |
|---|---|
| `request-executed.json` | `PRX-R-010` — envelope with no identity, no credential, no URL |
| `decision-executed.json` | `PRX-R-020`, `PRX-R-013`, `PRX-R-054` |
| `request-sensitive-read.json` | a read of a known-sensitive resource — the case that used to be refused |
| `decision-executed-handle-substituted.json` | `PRX-R-055` — key names and structure returned, both secret values replaced by handles, `handles_substituted: 2`. The agent learns the wiring already exists without seeing a byte of it |
| `request-gated.json` | a mutation the classifier flags `costsMoney` |
| `frozen-object.json` | `PRX-R-040` — the resolved upstream object the proxy persists and executes |
| `decision-pending.json` | `PRX-R-040`, `PRX-R-041`, `PRX-R-043`; `frozen_hash` is the JCS SHA-256 of `frozen-object.json`. The `preview` carries a what-if diff and an Infracost figure — that, not the request, is what the approver sees |
| `decision-refused-never-list.json` | `PRX-R-036` — the load-bearing refusal. Terminal, not escalatable, and names the IaC-PR route |
| `decision-refused-out-of-ring.json` | `PRX-R-033`, `PRX-R-036` — escalatable, and echoes only what the agent supplied |
| `decision-refused-handle-in-tag.json` | `PRX-R-052` — the exfiltration path, closed |
| `decision-refused-warrant-dead.json` | `PRX-R-003` — TTL elapsed, carrying `cause` |
| `decision-error.json` | `PRX-R-021`, `PRX-R-023` — `class: upstream`, retryable |
| `decision-error-malformed.json` | `PRX-R-002`, `PRX-R-023` — `class: client`, never retryable. A client fault is not a permission decision |
| `decision-error-proxy-underscoped.json` | `PRX-R-023` — an upstream 403 that means the *proxy's* credential is wrong. `class: proxy`, pages an operator, and explicitly tells the agent not to look for another route |
| `request-secret-handle.json` | `PRX-R-050`, `PRX-R-052` — handle in a field that accepts one |

All four `reason_code` values and all three error `class` values have a fixture. That is the
point of keeping both enums small enough to enumerate.

## Regenerating `frozen_hash`

```
python3 -c '
import json,hashlib
o=json.load(open("frozen-object.json"))
print("sha256:"+hashlib.sha256(json.dumps(o,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest())'
```

That one-liner is a JCS *subset* — correct for these fixtures because they contain no floats
requiring ES6 number serialisation and no strings needing escape normalisation. The
implementation MUST use a real RFC 8785 library; see `open-questions.md` Q3.
