# Model credentials for a credential-isolated agent

**Purpose:** the agent must hold no credential, and that has to include the *model*
credential — otherwise there is still one live token readable from inside the sandbox.
This records what was measured while making that true for GitHub Copilot on the k3d
prototype, and what the alternatives look like. Research plus verification, not a spec;
nothing here changes a `MUST`.

**Measured against opencode 1.18.16, pinned.** That version matters: opencode's Copilot
integration is young and has been restructured more than once. Re-verify on upgrade.

## The short version

GitHub Copilot works and is what the prototype uses. A **PAT cannot** authenticate to the
Copilot API — that is not a configuration problem, it is a different product with a
different credential. GitHub Models is the PAT-friendly cousin and would have been simpler,
but its free tier is rate-limited far below what a coding agent consumes.

## What was verified, and how

| Claim | Method | Result |
|---|---|---|
| A PAT cannot call `api.githubcopilot.com` | direct request | **400** for the PAT (as Bearer *and* as x-access-token Basic); **200** for the Copilot token |
| opencode never exchanges the Copilot token | `grep -a` on the pinned binary | `copilot_internal` → **0 occurrences** |
| The Copilot token is static | inspected `auth.json` | `expires: 0`, `access == refresh`, both `gho_`, 40 chars |
| opencode does not validate the credential | `opencode models` with a fake value | `GITHUB_TOKEN=proxy-managed` → **8 models becomes 41**, including `github-copilot/*` |
| Copilot token scope is narrow | request to `api.github.com` | `X-OAuth-Scopes: read:user` only — private repos 0 items, `/user/orgs` 403, `/gists` 403 |
| opencode honours `HTTPS_PROXY` | in-pod model listing through the proxy | models.dev fetch succeeded through the proxy |

The decisive one is row 4. Because the provider loads on a placeholder, **no real
credential and no `auth.json` need exist in the pod at all** — the proxy substitutes the
real token on the wire. That is stronger than mounting a read-only placeholder file: there
is nothing on the volume to protect and nothing to write-protect.

### A false negative worth not repeating

An earlier investigation probed `api.github.com/copilot_internal/v2/token`, got four
consistent 403s, and concluded the Copilot credential could not work. That was wrong —
opencode never calls that endpoint. Four consistent failures from an endpoint outside the
code path prove nothing.

The likely explanation, and it reconciles both observations: opencode's own OAuth App
client ID issues **`gho_`** tokens, which go straight to the Copilot API as a Bearer.
The `ghu_` GitHub-App user tokens that some editors use *do* require exchange via that
endpoint. Different token family, different flow — both facts true at once.

The same trap recurred while writing this: a `strings`-based probe of the binary reported
0 occurrences of *everything*, including strings known to be present, because the image has
no `strings` binary and every call silently produced nothing. **Always include a control
probe that must return a non-zero count**, or a broken method looks like a negative result.

## Options considered

**A. Real `auth.json` in the pod.** Simplest, works, but leaves a live credential readable
by the agent — the thing the design exists to prevent. Rejected.

On a *shared* state volume it is actively worse than it looks: a placeholder file does not
prevent write-back, because a completed `opencode auth login` would overwrite it with a real
token that every pod can then read. If this route is ever taken, the mount must be
read-only — the placeholder value is not the enforcement, the mount mode is.

**B. Copilot token in the proxy.** What shipped. A separate `COPILOT_HOSTS` rule using
`Bearer`, never merged into `GITHUB_HOSTS` (different credential *and* different scheme —
merging fails as a confusing 400 from the model API rather than an obvious auth error).
Fails closed when unset, so the Docker setup is unaffected until it opts in.

**C. GitHub Models.** A separate product from Copilot: OpenAI-compatible endpoint,
authenticated with an ordinary **PAT** (`models:read` for fine-grained tokens), static
Bearer, no OAuth and nothing to refresh. Architecturally it is the best fit — it would flow
through the *existing* PAT injection with no new proxy rule at all.

Rejected for now on **rate limits**: the free tier is roughly 10 requests/minute and
50/day per model. A single coding-agent task can exhaust that. Worth revisiting on a paid
tier. Note also that `github-models` appears as a known provider ID in opencode's catalog,
but is not enabled by the obvious environment variables (`GITHUB_MODELS_TOKEN`,
`GITHUB_MODELS_API_KEY`, `GITHUB_API_KEY` were all tried and none worked) — its endpoint is
not in the binary and comes from models.dev at runtime, so wiring it up needs more digging
than a single env var.

**D. A plain vendor API key** (Anthropic Console, OpenAI, or any OpenAI-compatible
gateway). Structurally the cleanest: static key, no OAuth, no seat, no interactive-use
question, and supported through opencode's documented
`provider.<id>.options.apiKey` with `{env:VAR}` interpolation. Costs money per token, which
is the only reason it is not the default here. Note this means an *API* key, not a
consumer subscription's OAuth token.

## Open, and worth deciding deliberately

- **Whose Copilot identity should the sandbox use?** The prototype uses a personal seat's
  token. GitHub's terms make the account owner responsible for what automation does with
  it, so the human whose seat it is should at least know their identity is what drives the
  agent. GitHub has publicly blessed opencode as a Copilot client, but that statement was
  made about a human running an interactive CLI — whether it extends to fully unattended
  operation is not something the public terms address. If this ever runs unattended, get a
  real answer rather than inferring one.
- **Untested:** whether a 401 from `api.githubcopilot.com` triggers an OAuth refresh
  attempt. It should not fire, since the proxy substitutes a valid token before the request
  leaves.
- **Version-sensitive:** if opencode ever adopts a `ghu_`-style client ID, the static-Bearer
  path stops working and a token-exchange call to `api.github.com` appears — a *new*
  endpoint the proxy would need a rule for. Re-check on upgrade.
