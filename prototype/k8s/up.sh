#!/usr/bin/env bash
#
# up.sh — minimal Kubernetes version of ai-sandbox's sandbox.sh `start`.
#
# This is a SEPARATE project from ai-sandbox on purpose — it doesn't live
# inside that repo and isn't tracked in its git history. The only thing it
# takes from ai-sandbox is build CONTEXT for three Dockerfiles (proxy/,
# github-mcp/, agent/), read from AI_SANDBOX_DIR below. It does not import
# ai-sandbox's scripts, source its lib/, or assume anything about where this
# project's own files sit relative to it. If ai-sandbox's Dockerfiles change
# shape, only the AI_SANDBOX_DIR paths here need to track that — nothing
# else about this project does.
#
# Scope, deliberately narrow: one agent pod with GitHub access via the same
# proxy/MCP pattern ai-sandbox uses (see AI_SANDBOX_DIR/proxy/
# inject_github_token.py, AI_SANDBOX_DIR/github-mcp/ — both reused
# UNCHANGED, no image edits). No az-mcp or k8s-mcp relay here: those exist
# so the agent can act as a CLIENT of some OTHER cluster, unrelated to
# getting a PR out of this one. Add them back later if/when that's actually
# needed.
#
# UNLIKE sandbox.sh, this script does NOT resolve or inject a GitHub token
# itself — no host Keychain lookup, no `gh auth token` fallback. You create
# the github-token-real Secret by hand, once, before running this (see
# step 4 below for the exact command). This script only checks the Secret
# exists and does a non-fatal read-back of its scopes.
#
# "Steer" and "view progress": the agent pod runs `opencode serve` as its
# main process, and each human joins with `opencode attach`. This was
# checked empirically against a real cluster rather than assumed, and the
# assumption it replaces was WRONG:
#
#   Session-DB persistence does NOT make a second `opencode` show the live
#   session. Every plain `opencode` invocation is an independent TUI with
#   its own in-process server. Two of them share only the SQLite DB, so the
#   second sees the first's session HISTORY, never its live session — you
#   can read what already happened, but you cannot steer what is happening.
#
# Verified in-cluster: two concurrent `opencode attach --session <id>`
# clients against one `opencode serve` both stayed live on the SAME session,
# no lock contention, no "session busy". That is the steer/watch path.
#
# Usage: ./up.sh          (takes no arguments)
#
# The agent pod is named agent-<random>. Nothing from the host is mounted;
# the agent clones its own workspace.

set -euo pipefail

SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Where ai-sandbox actually lives — override if it's not a sibling of $HOME.
# This is the one and only seam between the two projects.
AI_SANDBOX_DIR="${AI_SANDBOX_DIR:-$HOME/ai-sandbox}"

CLUSTER_NAME="${AI_SANDBOX_K8S_CLUSTER:-ai-sandbox}"
NAMESPACE="${AI_SANDBOX_K8S_NAMESPACE:-agent-sandbox}"
CONTEXT="k3d-$CLUSTER_NAME"

PROXY_IMAGE="ai-sandbox-proxy:latest"
GITHUB_MCP_IMAGE="ai-sandbox-github-mcp:latest"
AGENT_IMAGE="ai-sandbox-agent:latest"

log()  { printf '[up] %s\n' "$*"; }
warn() { printf '\033[33m[up] %s\033[0m\n' "$*" >&2; }
ok()   { printf '\033[32m[up] %s\033[0m\n' "$*"; }
die()  { printf '\033[31m[up] %s\033[0m\n' "$*" >&2; exit 1; }

for bin in k3d kubectl docker envsubst; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin not found — install it first"
done

for d in proxy github-mcp agent; do
  [ -f "$AI_SANDBOX_DIR/$d/Dockerfile" ] \
    || die "$AI_SANDBOX_DIR/$d/Dockerfile not found — set AI_SANDBOX_DIR to your ai-sandbox checkout"
done

# This script takes no positional argument. The agent pod's name is GENERATED
# (agent-<random>), not derived from a project directory or repo name.
#
# There is no project concept here to name a pod after: nothing from the host
# is mounted, and the workspace is an empty PVC the agent fills with its own
# `git clone`. A name like `agent-my-repo` would assert a binding between pod
# and repo that nothing enforces — the pod is just a place an agent runs, and
# which repo it works on is decided per task, not per pod.
if [ "$#" -gt 0 ]; then
  warn "ignoring argument '$1' — this script takes none; the pod name is generated"
fi

kctl() { kubectl --context "$CONTEXT" -n "$NAMESPACE" "$@"; }

# 1. Cluster
if ! k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"$CLUSTER_NAME\""; then
  log "creating k3d cluster $CLUSTER_NAME"
  # traefik and servicelb are disabled deliberately. Nothing in this design
  # uses an Ingress — the proxy and MCP bridge are ClusterIP Services reached
  # by in-cluster DNS, and the human reaches the agent via `kubectl exec`, not
  # over HTTP. Leaving them on is not neutral: on a 7.7 GiB Docker VM already
  # hosting the Docker ai-sandbox stack, the traefik helm-install job was
  # observed backing off and retrying twice before succeeding, and the node
  # logged SystemOOM with opencode as the victim. Dropping both removes a
  # helm job, the traefik pod and the svclb DaemonSet for no loss of function.
  k3d cluster create "$CLUSTER_NAME" \
    --k3s-arg '--disable=traefik@server:*' \
    --k3s-arg '--disable=servicelb@server:*' >/dev/null
  ok "cluster created"
else
  # Existence is NOT readiness. A cluster that was never deleted is still there
  # after Docker Desktop is quit or the machine reboots — but every node container
  # is STOPPED, and reusing it blindly gets you a script that sails past this check
  # and then fails on every kubectl call with a connection error. `k3d cluster start`
  # is a no-op on an already-running cluster, so this is safe to do unconditionally.
  log "cluster $CLUSTER_NAME exists — ensuring its nodes are started"
  k3d cluster start "$CLUSTER_NAME" >/dev/null 2>&1 || true
  ok "cluster $CLUSTER_NAME ready"
fi

# 2. Images — built like sandbox.sh does, then imported into k3d's own
# containerd (k3d nodes don't see the host Docker image store directly).
build_and_import() {
  local image="$1" ctx="$2"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    log "building $image"
    docker build -t "$image" "$ctx" >/dev/null
  fi
  log "importing $image into $CLUSTER_NAME"
  k3d image import "$image" -c "$CLUSTER_NAME" >/dev/null
}
build_and_import "$PROXY_IMAGE" "$AI_SANDBOX_DIR/proxy"
build_and_import "$GITHUB_MCP_IMAGE" "$AI_SANDBOX_DIR/github-mcp"
build_and_import "$AGENT_IMAGE" "$AI_SANDBOX_DIR/agent"
ok "images ready"

# 3. Namespace
kubectl --context "$CONTEXT" get ns "$NAMESPACE" >/dev/null 2>&1 \
  || kubectl --context "$CONTEXT" create ns "$NAMESPACE" >/dev/null
ok "namespace $NAMESPACE ready"

# 4. GitHub token secret — YOU create this, not this script. It must NOT
# carry the `workflow` scope: GitHub refuses, server-side, to let a token
# without it push/modify .github/workflows/* — see
# $AI_SANDBOX_DIR/lib/gh-token.sh's comment for the full reasoning, which
# still applies even though this script no longer resolves the token itself.
#
#   kubectl --context k3d-ai-sandbox -n agent-sandbox create secret generic \
#     github-token-real --from-literal=token=<YOUR_GITHUB_TOKEN>
#
# (create the namespace first if it doesn't exist yet — this script's own
# namespace-creation step above already did that for you, if you're running
# this end to end.)
if ! kctl get secret github-token-real >/dev/null 2>&1; then
  die "secret github-token-real not found in namespace $NAMESPACE — create it first:
  kubectl --context $CONTEXT -n $NAMESPACE create secret generic github-token-real \\
    --from-literal=token=<YOUR_GITHUB_TOKEN_WITHOUT_WORKFLOW_SCOPE>"
fi
ok "github token secret found"

# The Copilot/model credential is OPTIONAL and separate — a different identity
# under a different scheme (see the proxy addon's COPILOT_HOSTS). Absent, the
# stack comes up fine and only model calls fail, so this reports rather than dies.
if kctl get secret copilot-token-real >/dev/null 2>&1; then
  ok "copilot model-token secret found — proxy will inject it for api.githubcopilot.com"
else
  warn "no copilot-token-real secret — the agent will have NO model credential"
  warn "  create it, then: kubectl -n $NAMESPACE rollout restart deploy/proxy"
fi

# Non-fatal scope check against whatever is already in the secret — this
# reads it back and asks GitHub about it, it does not create or resolve
# anything itself.
gh_token_check="$(kctl get secret github-token-real -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
if [ -n "$gh_token_check" ] && command -v curl >/dev/null 2>&1; then
  # Status AND scopes from ONE request. Both are needed: the scope header
  # alone cannot tell "valid token that happens to carry no scopes" apart
  # from "token GitHub rejected outright", and those need opposite reactions.
  #
  # This previously reported a reassuring "no 'workflow' scope" for BOTH,
  # because the case subject was written `...,": in` — a stray quote+colon
  # appended a ':' to the subject, so the empty-header arm could never match
  # and everything fell through to the success arm. A safety check that
  # always passes is worse than no check, so it now names what it saw.
  gh_hdrs="$(curl -sS -o /dev/null -D - --max-time 10 \
    -H "Authorization: token $gh_token_check" \
    https://api.github.com/ 2>/dev/null | tr -d '\r' || true)"
  gh_status="$(printf '%s\n' "$gh_hdrs" | sed -n 's|^HTTP/[0-9.]* *\([0-9]*\).*|\1|p' | tail -1)"
  scopes_header="$(printf '%s\n' "$gh_hdrs" \
    | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p' | tail -1)"

  case "$gh_status" in
    401|403)
      warn "GitHub REJECTED the token in github-token-real (HTTP $gh_status)"
      warn "  every GitHub call the agent makes through the proxy will fail"
      ;;
    2*)
      case ",$(printf '%s' "$scopes_header" | tr -d ' ')," in
        *,workflow,*)
          warn "the token in github-token-real CARRIES the 'workflow' scope"
          warn "  the agent will be able to push .github/workflows/* changes — see $AI_SANDBOX_DIR/lib/gh-token.sh"
          ;;
        ,,)
          # Fine-grained PAT or App token: GitHub sends no X-OAuth-Scopes at
          # all, so classic-scope reasoning does not apply and the workflow
          # restriction cannot be confirmed from here. Say so rather than
          # implying a clean bill of health.
          warn "token is valid but reports no OAuth scopes (fine-grained PAT or App token)"
          warn "  cannot confirm from here whether it can write .github/workflows/*"
          ;;
        *) ok "token valid, and carries no 'workflow' scope" ;;
      esac
      ;;
    *)
      warn "could not reach GitHub to check the token (HTTP '${gh_status:-no response}') — skipping scope check"
      ;;
  esac
  unset gh_hdrs gh_status scopes_header
fi
unset gh_token_check

# 5. Proxy — apply, wait ready, extract its self-signed CA, publish as a
# Secret the other pods trust.
kctl apply -f "$SELF_DIR/proxy.yaml" >/dev/null
kctl rollout status deploy/proxy --timeout=120s >/dev/null
ok "proxy running"

proxy_pod="$(kctl get pod -l app=proxy -o jsonpath='{.items[0].metadata.name}')"
ca_pem=""
for _ in $(seq 1 30); do
  ca_pem="$(kctl exec "$proxy_pod" -- cat /home/mitmproxy/.mitmproxy/mitmproxy-ca-cert.pem 2>/dev/null || true)"
  [ -n "$ca_pem" ] && break
  sleep 1
done
[ -n "$ca_pem" ] || die "proxy never produced a CA certificate — check: kubectl --context $CONTEXT -n $NAMESPACE logs deploy/proxy"
tmp_ca="$(mktemp)"
printf '%s\n' "$ca_pem" > "$tmp_ca"
kctl create secret generic mitm-ca --from-file=mitm-proxy-ca.crt="$tmp_ca" \
  --dry-run=client -o yaml | kctl apply -f - >/dev/null
rm -f "$tmp_ca"
ok "credential-proxy CA published"

# 6. GitHub MCP bridge
kctl apply -f "$SELF_DIR/github-mcp.yaml" >/dev/null
kctl rollout status deploy/ai-sandbox-github-mcp --timeout=120s >/dev/null
ok "github MCP bridge running"

# 7. Agent pod — one per project. Never recreated if already running: it
# may have a live opencode session attached (same reasoning as sandbox.sh's
# cmd_start).
# Reuse an existing agent before minting a new one. With a generated name
# there is no deterministic name to look up, so the lookup is by label — and
# it still matters for the same reason it did before: a running pod may have
# a live opencode session attached, so it is never recreated underneath you.
# Set AI_SANDBOX_AGENT_POD to target a specific pod, or delete the existing
# one to get a fresh workspace.
agent_pod="${AI_SANDBOX_AGENT_POD:-}"
if [ -z "$agent_pod" ]; then
  agent_pod="$(kctl get pods -l app=agent \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi

if [ -n "$agent_pod" ] && kctl get pod "$agent_pod" >/dev/null 2>&1; then
  ok "agent pod already running ($agent_pod) — reused"
else
  # 6 random hex chars, the same shape k8s itself uses for generateName
  # suffixes. Not using generateName directly: the pod name has to be known
  # here to wait on it and to print the exec commands.
  #
  # `od` rather than the obvious `tr -dc ... </dev/urandom | head -c N`: that
  # pipeline SIGPIPEs `tr` once head has taken its bytes, and under
  # `set -o pipefail` the 141 propagates out of the command substitution and
  # kills this script with no message at all. `od -N` reads a bounded number
  # of bytes and exits on its own.
  agent_id="$(od -An -tx1 -N3 /dev/urandom | tr -d ' \n')"
  [ -n "$agent_id" ] || die "could not generate an agent id"
  agent_pod="agent-$agent_id"
  AGENT_POD_NAME="$agent_pod" AGENT_ID="$agent_id" \
    envsubst < "$SELF_DIR/agent-pod.yaml.tmpl" | kctl apply -f - >/dev/null
  kctl wait --for=condition=Ready "pod/$agent_pod" --timeout=120s >/dev/null
  ok "agent pod running ($agent_pod)"
fi

cat <<EOF

Ready. Steer, or just watch, the agent's live session. Two ways; the first is
nicer, and both attach to the SAME live session on the pod's \`opencode serve\`.

1. FROM YOUR OWN MACHINE, via port-forward (preferred — your real terminal,
   your fonts, your scrollback, no \`gosu\` dance):

     kubectl --context $CONTEXT -n $NAMESPACE port-forward pod/$agent_pod 4096:4096
     opencode attach http://127.0.0.1:4096

   This works even though the server binds 127.0.0.1 INSIDE the pod and is
   deliberately not exposed to the cluster network: port-forward enters the
   pod's network namespace, so loopback-only is reachable to you and to nobody
   else in the cluster. Verified: a session created this way is rooted at
   /workspace (the POD's path, server-side) — the client is thin, so running
   the TUI on a Mac does not corrupt paths.

   Your local opencode SHOULD match the pod's version (both 1.18.16 as built).
   Note this does expose the unauthenticated server to anything running on your
   own machine for as long as the port-forward is up; set
   OPENCODE_SERVER_PASSWORD on both ends if that matters to you.

2. INSIDE the pod, no port-forward needed:

     kubectl --context $CONTEXT -n $NAMESPACE exec -it $agent_pod -- \\
       gosu agent opencode attach http://127.0.0.1:4096

   \`gosu agent\` is not optional here. \`kubectl exec\` lands as ROOT (unlike
   sandbox.sh's \`docker exec -u agent\`), and opencode run as root writes
   root-owned files into /workspace and the state volume that the real agent
   user (uid 1000) then cannot rewrite.

Either way, add \`--session <id>\` to pin a specific session, or \`-c\` for the
most recent. Run it from as many terminals as you like.

List sessions:
  kubectl --context $CONTEXT -n $NAMESPACE exec $agent_pod -- \\
    gosu agent curl -sS --noproxy 127.0.0.1 http://127.0.0.1:4096/session

MODEL credential: the agent holds NONE, by design. It gets
GITHUB_TOKEN=proxy-managed, which is enough for opencode to offer the
github-copilot provider (it does not validate the value), while the real
Copilot token lives only in the proxy and is substituted on the wire for
api.githubcopilot.com. Do NOT run \`opencode auth login\` in the pod — it would
write a real token onto the shared state volume, which is the thing this
avoids. Create the Secret instead (the proxy picks it up on restart):

  kubectl --context $CONTEXT -n $NAMESPACE create secret generic \\
    copilot-token-real --from-literal=token=<gho_... COPILOT OAUTH TOKEN>
  kubectl --context $CONTEXT -n $NAMESPACE rollout restart deploy/proxy

Get that token from a host where you have signed in to Copilot: it is the
"access" field of the github-copilot entry in opencode's auth.json.

Note: git clone the target repo into /workspace as the agent's first task
(there's no host bind mount in this cluster setup, unlike the Docker
version), and set a git identity there — no host ~/.gitconfig is mounted, so
user.name/user.email are unset and commits will be refused:
  git -C /workspace/<repo> config user.name  "<name>"
  git -C /workspace/<repo> config user.email "<email>"
EOF
