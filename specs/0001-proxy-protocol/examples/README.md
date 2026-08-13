# Fixtures

Part of the spec, not illustrations. Changing one is a spec change; `tools/spec-trace`
validates them against `../schema/` on every run.

| Fixture | Demonstrates |
|---|---|
| `request-executed.json` | `PRX-R-010` — envelope with no identity, no credential, no URL |
| `decision-executed.json` | `PRX-R-020`, `PRX-R-013`, `PRX-R-054` |
| `request-gated.json` | a mutation the classifier flags `costsMoney` |
| `frozen-object.json` | `PRX-R-040` — the resolved upstream object the proxy persists and executes |
| `decision-pending.json` | `PRX-R-040`, `PRX-R-041`, `PRX-R-043`; `frozen_hash` is the JCS SHA-256 of `frozen-object.json`. Note the `preview` carries a what-if diff and an Infracost figure — that, not the request, is what the approver sees |
| `decision-refused-never-list.json` | `PRX-R-036` — refusal that is *not* escalatable |
| `decision-refused-sensitive-read.json` | `PRX-R-032` — refusal that names the working alternative (a handle) |
| `decision-refused-out-of-ring.json` | `PRX-R-033`, `PRX-R-036` — escalatable, and echoes only what the agent supplied |
| `decision-refused-malformed.json` | `PRX-R-002`, `PRX-R-030` — a client error still gets the full envelope |
| `decision-error.json` | `PRX-R-021` — broke, not denied |
| `request-secret-handle.json` | `PRX-R-050`, `PRX-R-052` — handle in a field that accepts one |
| `decision-refused-handle-in-tag.json` | `PRX-R-052` — the exfiltration path, closed |

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
