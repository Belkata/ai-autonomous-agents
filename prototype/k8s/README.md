# `prototype/k8s` — the agent sandbox on Kubernetes

A minimal Kubernetes version of what `ai-sandbox`'s `sandbox.sh` does with Docker: one
agent pod with GitHub access through a credential-holding proxy, which a human can join
to steer an in-progress session or just watch.

**Status: runs end to end on k3d, verified against a real cluster.** Everything below
marked VERIFIED was executed, not reasoned about. The one thing still not done is a full
task producing a PR.

## Relationship to `ai-sandbox`

This is a separate project. It borrows exactly one thing: build context for three
Dockerfiles (`proxy/`, `github-mcp/`, `agent/`), read from `AI_SANDBOX_DIR`
(default `$HOME/ai-sandbox`). It does not source that repo's scripts or `lib/`.

The images are used **unchanged** with one deliberate exception, added here: the proxy
addon `proxy/inject_github_token.py` gained a `COPILOT_HOSTS` rule (see *Credentials*).
That change is additive and backward-compatible — with `COPILOT_TOKEN_REAL` unset the
proxy behaves byte-identically, so the Docker setup is unaffected until it opts in.

## Quick start

```bash
./up.sh                 # takes NO arguments; the pod name is generated
```

First run stops at the missing GitHub token secret by design — this script never
resolves or injects a credential itself. Create the secrets, then run it again:

```bash
kubectl --context k3d-ai-sandbox -n agent-sandbox create secret generic \
  github-token-real --from-literal=token=<PAT WITHOUT 'workflow' SCOPE>

kubectl --context k3d-ai-sandbox -n agent-sandbox create secret generic \
  copilot-token-real --from-literal=token=<gho_... COPILOT OAUTH TOKEN>
```

Tear down with `./down.sh` (namespace) or `./down.sh --cluster` (everything).

The proxy reads both tokens as env vars **at container start**, so after changing either
secret: `kubectl -n agent-sandbox rollout restart deploy/proxy`. The agent pod and
github-mcp only ever hold placeholders and never need restarting for a credential change.

## Steering a live session

This is the part most worth reading, because the obvious approach does not work.

**Running `opencode` a second time does NOT show the live session.** Every plain
`opencode` invocation is an independent TUI with its own in-process server. Two of them
share only the SQLite session DB, so the second sees the first's *history* but never its
live session — resume-after-the-fact, not steering. The Docker design's assumption that
session-DB persistence was sufficient here was wrong.

opencode's real mechanism is a long-lived server plus thin attach clients. The pod runs
`opencode serve` as PID 1 and humans join with `opencode attach`.

**Preferred — from your own machine, via port-forward:**

```bash
kubectl --context k3d-ai-sandbox -n agent-sandbox port-forward pod/<agent-pod> 4096:4096
opencode attach http://127.0.0.1:4096
```

VERIFIED: this works even though the server binds `127.0.0.1` *inside* the pod and is
deliberately not exposed to the cluster network — `port-forward` enters the pod's network
namespace. A session created this way is rooted at `/workspace`, the **pod's** path, so
the client is thin and running the TUI on a Mac does not corrupt paths. Your local
opencode should match the pod's version (both 1.18.16 as built).

Caveat: while the forward is up, the **unauthenticated** server is reachable by anything
on your machine's localhost. Set `OPENCODE_SERVER_PASSWORD` on both ends if that matters.

**Alternative — inside the pod:**

```bash
kubectl --context k3d-ai-sandbox -n agent-sandbox exec -it <agent-pod> -- \
  gosu agent opencode attach http://127.0.0.1:4096
```

`gosu agent` is **not optional**. `kubectl exec` lands as ROOT — unlike `sandbox.sh`'s
`docker exec -u agent` — and opencode run as root writes root-owned files into
`/workspace` and the state volume that the real agent user (uid 1000) cannot then rewrite.

VERIFIED: two concurrent `opencode attach --session <id>` clients against one server both
stayed live on the same session, with no lock contention and no "session busy".

## Credentials — two identities, two schemes, neither in the agent

The agent holds **no real credential**. VERIFIED in-pod: the only token-shaped values it
can read are `GH_TOKEN=proxy-managed` and `GITHUB_TOKEN=proxy-managed`, and no
`auth.json` exists anywhere on its volumes.

| Traffic | Host(s) | Credential | Scheme |
|---|---|---|---|
| git / REST | `github.com`, `api.github.com`, `codeload…` | `GH_TOKEN_REAL` (PAT) | Basic, `x-access-token:<pat>` |
| model calls | `api.githubcopilot.com` | `COPILOT_TOKEN_REAL` (`gho_` OAuth) | **Bearer** |

These are kept in separate host sets on purpose: different credential *and* different
scheme. Merging them fails in the confusing direction — a 400 from the model API rather
than an obvious auth error.

**How the agent gets model access with no credential:** opencode's built-in
`github-copilot` provider declares `env:["GITHUB_TOKEN"]` and **does not validate the
value**. VERIFIED against 1.18.16: `GITHUB_TOKEN=proxy-managed` takes `opencode models`
from 8 entries to 41, including `github-copilot/*`. So the provider loads on a string
worthless anywhere else, and the proxy substitutes the real token on the wire.

This is stronger than mounting a read-only placeholder `auth.json`: there is no real
credential on the shared state volume to protect, and nothing to write-protect.

> **Do not "fix" `GITHUB_TOKEN` by removing it.** `ai-sandbox`'s AGENTS.md records that
> variable being *removed* from `run.sh`/`sandbox.sh` because it made opencode report an
> unvalidated Copilot credential. That was a bug when the value was accidental and no
> proxy rule existed. Here it is deliberate and paired with `COPILOT_HOSTS`. Removing it
> silently disables the agent's model access.

**Do not run `opencode auth login` in the pod** — it would write a real token onto the
shared state volume, which is the thing this design avoids.

VERIFIED end to end with real credentials: `git clone` through the proxy succeeded, and
`opencode run -m github-copilot/claude-haiku-4.5` returned a real completion.

Why Copilot and not something simpler — including why a PAT cannot work here, why GitHub
Models was rejected despite fitting the architecture better, and the open question of whose
Copilot identity the sandbox should use: `docs/model-credential-options-2026-08.md`.

### The `workflow` scope matters

The PAT must **not** carry the `workflow` scope. GitHub refuses, server-side, to let a
token without it push `.github/workflows/*` — an unbypassable control that stops the agent
authoring CI which would run with repository secrets. `up.sh` checks this and warns.

## Design notes

**No host mounts, ever.** No `hostPath`, no bind mount. The agent's workspace starts empty
and it populates it with its own `git clone` through the proxy. This is the main structural
difference from the Docker setup, where `sandbox.sh` bind-mounts the project directory at
its real host path.

**`up.sh` takes no arguments.** The pod name is generated (`agent-<random>`). There is no
project to name a pod after — nothing is mounted from the host, and which repo the agent
works on is decided per task, not per pod. An existing agent is found by **label** and
reused rather than recreated, since it may have a live session attached. Override with
`AI_SANDBOX_AGENT_POD`; delete the pod to get a fresh workspace.

**A Pod, not a Deployment** — a stable `kubectl exec` target whose name does not change
underneath you.

**Volumes.** `workspace-<agent-id>` is per-agent (clean workspace each time).
`opencode-state` is a single **shared, fixed-name** PVC — with generated pod names,
keying it per-pod would mean a brand new empty state volume every time. Note the
ReadWriteOnce constraint: several agent pods sharing it must land on the same node. True
on single-node k3d, a landmine on a multi-node cluster; revisit with RWX before that
matters.

**Traefik and servicelb are disabled.** Nothing here uses an Ingress. Leaving them on is
not neutral — on a 7.7 GiB Docker VM also hosting the Docker stack, the traefik
helm-install job backed off and retried twice, and the node logged `SystemOOM` with
opencode as the victim. Disabling both took the node from 1865Mi to 847Mi.

**The proxy is credential custody, not a network chokepoint.** Egress is open by design;
`HTTP_PROXY` is a convention clients honour voluntarily, not a boundary. MEASURED:
`curl --noproxy '*'` from the pod reaches the internet directly, and there is no
NetworkPolicy. Credential isolation holds regardless — the agent has no token to misuse —
but nothing that depends on containing *data* may lean on the network layer. See
`docs/design-note.md` for the accepted risk.

## Known gaps

- **No end-to-end PR yet.** Clone verified, a real model completion verified, but no full
  task has been run through to an opened pull request.
- **No git identity in the pod.** No host `~/.gitconfig` is mounted, so `user.name` /
  `user.email` are unset and commits will be refused until set in the cloned repo.
- **The workflow-file handoff needs a Kubernetes-appropriate channel.**
  `ai-sandbox`'s `agent/agent-instructions.md` used to tell the agent that "`/workspace` is a
  bind mount of the human's real project directory, so anything you commit is already visible
  to them". That is **false here** — `/workspace` is a PVC with no path to the host, so a
  withheld workflow commit dead-ends in a volume nobody reads. The instructions now describe
  both runtimes, but the k8s side still has no delivery mechanism. See below.

### Getting a withheld workflow change to a human

The token deliberately lacks the `workflow` scope, so the agent cannot push
`.github/workflows/*` — GitHub refuses server-side, unbypassably. That part works. The open
question is only how the human then *gets* the change.

**Recommended: keep it in the PR, at a path that cannot execute.** The agent commits the
proposed workflow to something like `.github/workflows-proposed/deploy.yml` and pushes it
normally. GitHub only runs files in `.github/workflows/`, so it triggers nothing, while the
change stays in the PR diff — reviewed with the tooling built for that, attributed to the
agent, with history and comments. The human's action becomes a one-line `git mv` commit,
itself trivially reviewable. No new channel and no host coupling.

NOT YET VERIFIED: that GitHub's refusal is scoped to `.github/workflows/` and a neighbouring
path pushes fine. Confirm before relying on it — it needs a token *without* the `workflow`
scope to test, which is a two-minute check.

**Pair it with CODEOWNERS on `.github/workflows/` plus required review.** That is the
unbypassable merge-time gate, and it holds with or without the token scope. Note that fork
PRs already get a read-only token and no secrets, plus first-time-contributor approval — so
the dangerous moment is the merge, not the PR.

**Rejected: pushing to a git remote on the developer's machine.** Technically possible —
`host.k3d.internal` resolves from the pod and there is no NetworkPolicy — but it inverts the
trust direction. The sandbox is the untrusted component; letting it initiate writes *into*
the developer's machine is strictly worse than letting it push to a fork, where the worst
case is a PR someone closes. It would also need a git server on the host (sshd is off by
default), a bare repo (pushing to a checked-out branch is refused), and an SSH key *in the
agent* — a credential in the agent, which is the thing this design exists to prevent.

Finally, it launders provenance: the human ends up pushing agent-authored CI under their own
identity, so git blame shows a person and any "trusted contributor" CI gating applies to code
the agent wrote.

**If an out-of-band channel is ever needed anyway, invert it: the human pulls.** `git bundle`
plus `kubectl cp`, or a port-forwarded read-only `git daemon` in the pod. No server on the
host, no credential in the agent, no new agent capability, and the human initiates it with
the kubectl access they already have.
- **k8s-mcp and az-mcp are not deployed.** Deliberate — those let the agent act as a client
  of some *other* cluster, unrelated to getting a PR out of this one.

## Bugs found and fixed while getting this to run

Recorded because none of them fail loudly, and two produced *reassuring* output.

1. **Slug generation appended a trailing dash to every name.** `basename` emits a trailing
   newline and `tr -c 'A-Za-z0-9-' '-'` maps every byte *outside* the set — so the newline
   became `-` and every resource was rejected as an invalid RFC 1123 name. (Now moot: names
   are generated.)
2. **The token scope check could never fail.** The case subject was written `...,": in` —
   a stray quote and colon appended `:` to the subject, so the empty-header arm never
   matched and everything fell through to the success arm. It printed a green
   *"no 'workflow' scope"* for a completely invalid token.
3. **`opencode serve` ran with the wrong working directory.** The image's `WORKDIR` is
   `/home/agent` and opencode roots a new session at the server's cwd, so sessions were
   rooted in the agent's home instead of the workspace. Fixed with `workingDir: /workspace`.
   This would never have surfaced as an error — just an agent quietly working in the wrong
   place.
4. **Random id generation killed the script silently.**
   `tr -dc … </dev/urandom | head -c N` SIGPIPEs `tr`; under `set -o pipefail` the 141
   propagated out of the command substitution and `set -e` exited with no message. Uses
   `od -N` now.

Two assumptions worth retiring, both checked rather than argued:

- **The proxy's `initContainer` chmod is unnecessary.** mitmproxy's own entrypoint runs
  `usermod -o -u $(stat -c %u …)` to match the mount's owner, and local-path already
  creates PVC directories `0777`. Side effect worth knowing: because the PVC root is
  root-owned, that `usermod` makes mitmproxy run as uid 0 either way.
- **`api.github.com/copilot_internal/v2/token` is not in opencode's code path.** Confirmed
  against the pinned binary: 0 occurrences. There is no token exchange and no refresh —
  the `gho_` token goes straight through as a static Bearer (`expires: 0`,
  `access == refresh`).

Also corrected: `ai-sandbox`'s AGENTS.md says macOS opencode stores state under
`~/.config/opencode/`. On the Mac used here that path does not exist — `auth.json` is at
`~/.local/share/opencode/auth.json`, the same as Linux.
