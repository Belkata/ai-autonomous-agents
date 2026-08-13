# Scoped autonomy

A control plane that lets AI agents do platform and infrastructure work — take a task, write
code, open PRs, touch infrastructure — without ever holding a credential, and with a human
gate on anything destructive or costly.

```
person chats with intake agent
  → agent interviews, reads repos + live infra (read-only)
  → one preview card, one signature
  → ticket (for humans) + Warrant (for machines)
  → sandboxed coding agent runs, holding zero credentials
  → PR  |  approval card  |  escalation request
```

**Status:** specification. No implementation yet.

## Where things are

| | |
|---|---|
| Design rationale, narrative | [design note](https://claude.ai/code/artifact/9953c5cd-cb3c-4c89-aa4b-672c7e36f5bd) |
| Normative behaviour | [`specs/`](specs/) — start with [`specs/README.md`](specs/README.md) |
| What gets specified, in what order | [`specs/ROADMAP.md`](specs/ROADMAP.md) |
| First spec | [`specs/0001-proxy-protocol/`](specs/0001-proxy-protocol/spec.md) |
| Settled decisions | [`CLAUDE.md`](CLAUDE.md) |

## Checks

```
uv run tools/spec-trace/spec_trace.py
```

Validates spec structure, checks every `MUST` in an accepted spec has a test carrying its ID,
and validates the golden fixtures against their schemas.

## Two things this is not

**Not a policy engine that thinks in tool names.** Every agent runtime can allowlist a tool.
This classifies a request by what it will actually do — destroy something, cost €400 a month,
return a secret — and puts a rendered diff in front of a human instead of a command string.

**Not a system where a denial ends the run.** A refusal is a structured message that becomes
a request to a human, and the run resumes where it stopped, hours later.

## Licence

Apache-2.0. See [`LICENSE`](LICENSE).
