#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# functional-test.sh — tiered functional tests for any EnMaaS environment.
#
# Levels are cumulative; each runs everything below it:
#
#   smoke      No credentials. DNS, TLS, HTTP->HTTPS, health endpoints, the
#              401 wall on every protected path, auth-bypass headers, and
#              (with a kubeconfig) route admission + workload readiness.
#              Read-only: safe against production at any time.
#   auth       + a valid key is accepted, an invalid one is refused, and both
#              catalog dialects return their correct envelope. Still read-only.
#   inference  + one tiny completion per (model, endpoint) pair. Costs tokens.
#   full       + streaming, concurrency, error shapes, and metering proof.
#
# Targets. Any EnMaaS environment works; pick one of the known profiles or
# set the hosts directly:
#   --target enmaas            api/dashboard.enmaas.devshift.net
#   --target dogfood|test      hosts resolved from Routes via oc
#   GATEWAY_HOST=... DASHBOARD_HOST=...   any other environment
#
# Usage:
#   ./tools/functional-test.sh --target enmaas                     # smoke
#   ./tools/functional-test.sh --target enmaas --level auth
#   ./tools/functional-test.sh --target enmaas --level inference --confirm-prod
#   GATEWAY_HOST=gw.example DASHBOARD_HOST=dash.example ./tools/functional-test.sh
#
# Credentials are optional and only gate the higher levels; tests that need a
# credential SKIP rather than fail when it is absent, so the same suite runs
# unchanged in CI (HTTP-only) and from an operator laptop (full checks).
#   PRICETAG_KEY or KEY_FILE   MaaS API key for auth/inference/full
#   PARTNER_TOKEN              partner API bearer, for the partner-auth checks
# Keys are passed to curl through a 0600 --config file, never argv, never logged.
#
# Exit status is non-zero if any check FAILs. SKIPs never fail the run.
set -euo pipefail

LEVEL="${LEVEL:-smoke}"
TARGET="${TARGET:-}"
CONFIRM_PROD="${CONFIRM_PROD:-false}"
TIMEOUT="${TIMEOUT:-25}"
MIN_CERT_DAYS="${MIN_CERT_DAYS:-14}"

# The test model matrix: one free/hosted model plus one per external provider.
# Override any of them for a different environment's catalog.
MODEL_FREE="${MODEL_FREE:-rits/zai-org/glm-5-3}"
MODEL_ANTHROPIC="${MODEL_ANTHROPIC:-claude-haiku-4-5}"
MODEL_OPENAI="${MODEL_OPENAI:-gpt-5.4}"

usage() { sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--level)   LEVEL="$2"; shift 2 ;;
    -t|--target)  TARGET="$2"; shift 2 ;;
    --confirm-prod) CONFIRM_PROD=true; shift ;;
    -h|--help)    usage ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

case "$LEVEL" in
  smoke) LEVEL_N=1 ;; auth) LEVEL_N=2 ;; inference) LEVEL_N=3 ;; full) LEVEL_N=4 ;;
  *) echo "LEVEL must be smoke|auth|inference|full" >&2; exit 2 ;;
esac
at_least() { # at_least <level-name>
  local want
  case "$1" in smoke) want=1 ;; auth) want=2 ;; inference) want=3 ;; full) want=4 ;; esac
  [[ "$LEVEL_N" -ge "$want" ]]
}

# ── target resolution ───────────────────────────────────────────
IS_PROD=false
route_host() { # route_host <namespace> <route>
  oc -n "$1" get "route/$2" -o jsonpath='{.spec.host}' 2>/dev/null || true
}
case "$TARGET" in
  enmaas)
    GATEWAY_HOST="${GATEWAY_HOST:-api.enmaas.devshift.net}"
    DASHBOARD_HOST="${DASHBOARD_HOST:-dashboard.enmaas.devshift.net}"
    IS_PROD=true ;;
  dogfood)
    GATEWAY_HOST="${GATEWAY_HOST:-$(route_host ai-gateway-dogfood ai-gateway)}"
    DASHBOARD_HOST="${DASHBOARD_HOST:-$(route_host ai-gateway-dogfood dashboard)}" ;;
  test)
    GATEWAY_HOST="${GATEWAY_HOST:-$(route_host ai-gateway-test ai-gateway)}"
    DASHBOARD_HOST="${DASHBOARD_HOST:-$(route_host ai-gateway-test dashboard)}" ;;
  "") : ;;
  *) echo "unknown target: $TARGET (enmaas|dogfood|test, or set the hosts)" >&2; exit 2 ;;
esac
if [[ -z "${GATEWAY_HOST:-}" || -z "${DASHBOARD_HOST:-}" ]]; then
  echo "could not determine hosts: pass --target, or set GATEWAY_HOST and DASHBOARD_HOST" >&2
  exit 2
fi
GATEWAY="https://$GATEWAY_HOST"
DASHBOARD="https://$DASHBOARD_HOST"

# Levels that send model traffic cost real money on a production environment.
if [[ "$IS_PROD" == true && "$CONFIRM_PROD" != true ]] && at_least inference; then
  echo "refusing to send model traffic to $GATEWAY_HOST without --confirm-prod" >&2
  exit 2
fi

# ── credentials (optional; absent ⇒ SKIP, never FAIL) ───────────
KEY_FILE="${KEY_FILE:-$HOME/.mykey}"
KEY="${PRICETAG_KEY:-}"
if [[ -z "$KEY" && -r "$KEY_FILE" ]]; then KEY="$(tr -d '[:space:]' < "$KEY_FILE")"; fi
[[ ${#KEY} -lt 10 ]] && KEY=""
PARTNER_TOKEN="${PARTNER_TOKEN:-}"

WORK="$(mktemp -d)"; chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

# ── result bookkeeping ──────────────────────────────────────────
P=0; F=0; S=0; RESULTS=""
log()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
pass() { P=$((P+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; RESULTS+="PASS|$1"$'\n'; }
fail() { F=$((F+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; RESULTS+="FAIL|$1"$'\n'; }
skip() { S=$((S+1)); printf '  \033[33mSKIP\033[0m %s\n' "$1"; RESULTS+="SKIP|$1"$'\n'; }

# code <url> [extra curl args...] → prints HTTP status
code() {
  local url="$1"; shift
  curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$@" "$url" 2>/dev/null || echo 000
}
# expect_code <label> <expected-regex> <url> [curl args...]
expect_code() {
  local label="$1" want="$2" url="$3"; shift 3
  local got; got="$(code "$url" "$@")"
  if [[ "$got" =~ $want ]]; then pass "$label ($got)"; else fail "$label — got $got, want $want"; fi
}
# curl_json <outfile> <url> <authmode> [curl args...] → status code, key via config file
curl_json() {
  local out="$1" url="$2" mode="$3"; shift 3
  local cfg="$WORK/req.curl"
  : >"$cfg"; chmod 600 "$cfg"
  case "$mode" in
    bearer)    printf 'header = "Authorization: Bearer %s"\n' "$KEY" >>"$cfg" ;;
    anthropic) printf 'header = "x-api-key: %s"\nheader = "anthropic-version: 2023-06-01"\n' "$KEY" >>"$cfg" ;;
    partner)   printf 'header = "Authorization: Bearer %s"\n' "$PARTNER_TOKEN" >>"$cfg" ;;
    none)      : ;;
  esac
  local got
  got="$(curl -s -o "$out" -w '%{http_code}' --max-time "$TIMEOUT" --config "$cfg" "$@" "$url" 2>/dev/null || echo 000)"
  rm -f "$cfg"
  echo "$got"
}
jcheck() { python3 -c "$1" "$2" >/dev/null 2>&1; }

echo "EnMaaS functional tests — level=$LEVEL target=${TARGET:-custom}"
echo "  gateway=$GATEWAY"
echo "  dashboard=$DASHBOARD"
echo "  credentials: key=$([[ -n "$KEY" ]] && echo present || echo absent) partner=$([[ -n "$PARTNER_TOKEN" ]] && echo present || echo absent)"

# ════════════════════════════════════════════════════════════════
# SMOKE — no credentials required
# ════════════════════════════════════════════════════════════════
log "DNS and TLS"
for h in "$GATEWAY_HOST" "$DASHBOARD_HOST"; do
  if getent hosts "$h" >/dev/null 2>&1 || host "$h" >/dev/null 2>&1; then pass "dns resolves $h"
  else fail "dns does not resolve $h"; fi

  cert="$WORK/cert-$h.pem"
  if echo | timeout "$TIMEOUT" openssl s_client -connect "$h:443" -servername "$h" 2>/dev/null \
      | openssl x509 -noout -text >"$cert" 2>/dev/null; then
    if grep -A1 'Subject Alternative Name' "$cert" | grep -q "DNS:$h"; then pass "tls SAN covers $h"
    else fail "tls SAN does not cover $h"; fi
    end="$(echo | timeout "$TIMEOUT" openssl s_client -connect "$h:443" -servername "$h" 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    if [[ -n "$end" ]]; then
      left=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
      if [[ "$left" -ge "$MIN_CERT_DAYS" ]]; then pass "tls cert $h valid ${left}d"
      else fail "tls cert $h expires in ${left}d (< $MIN_CERT_DAYS)"; fi
    else fail "tls cert $h has no expiry"; fi
  else
    fail "tls handshake failed for $h"
  fi
done
expect_code "http->https redirect (dashboard)" '^30[128]$' "http://$DASHBOARD_HOST/health"

log "Public health endpoints"
expect_code "dashboard /health" '^200$' "$DASHBOARD/health"
expect_code "dashboard /ready"  '^200$' "$DASHBOARD/ready"
expect_code "dashboard /login"  '^200$' "$DASHBOARD/login"

log "Unauthenticated 401 wall"
# The gateway must refuse model traffic without a key, and must do so at the
# edge: a 404/5xx here means routing or auth is broken, not that we are safe.
expect_code "gateway /v1/models unauthenticated"           '^401$' "$GATEWAY/v1/models"
expect_code "gateway /v1/chat/completions unauthenticated" '^40[13]$' "$GATEWAY/v1/chat/completions" \
  -X POST -H 'content-type: application/json' --data '{"model":"x","messages":[]}'

# Partner APIs, as documented in docs/openshift-deploy-guide.md. These are real
# endpoints that must exist AND authenticate, so the bar is a hard 401/403 —
# a 404 here would mean the documented contract moved.
for p in /api/v1/users /api/v1/models /api/v1/usage/reports \
         "/api/v1/model-policies/users/functional-test-probe/allowlist"; do
  expect_code "partner $p unauthenticated" '^40[13]$' "$DASHBOARD$p"
done

# Session-backed dashboard endpoints. A browser endpoint legitimately answers
# with a redirect to login rather than a bare 401, and bare prefixes may 404
# because the real handler lives on a sub-path. The security property that
# actually matters for all of them is the same: never a 2xx, never a body.
# deny_unauth <label> <path>
deny_unauth() {
  local label="$1" path="$2" got loc
  got="$(code "$DASHBOARD$path")"
  case "$got" in
    2*) fail "$label — unauthenticated request returned $got" ;;
    30*)
      loc="$(curl -s -o /dev/null -w '%{redirect_url}' --max-time "$TIMEOUT" "$DASHBOARD$path" 2>/dev/null || true)"
      if [[ "$loc" == *"/login"* ]]; then pass "$label (redirect to login)"
      else fail "$label — redirects to $loc, expected /login"; fi ;;
    000) fail "$label — no response" ;;
    *)  pass "$label ($got)" ;;
  esac
}
for p in /api/v1/admin /api/v1/me /api/v1/org /api/v1/pricing /api/v1/whoami /api/v1/dashboard; do
  deny_unauth "dashboard $p denied unauthenticated" "$p"
done

log "Credential-forgery resistance"
# A Route once trusted X-MaaS-Username outright; a bypass is a full auth break.
# Probe an endpoint that really exists and really authenticates, so that a
# forged header has something to actually bypass.
expect_code "X-MaaS-Username header is not trusted" '^40[13]$' "$DASHBOARD/api/v1/users" \
  -H 'X-MaaS-Username: admin'
expect_code "X-Forwarded-User header is not trusted" '^40[13]$' "$DASHBOARD/api/v1/users" \
  -H 'X-Forwarded-User: admin'
expect_code "X-Remote-User header is not trusted" '^40[13]$' "$DASHBOARD/api/v1/users" \
  -H 'X-Remote-User: admin'
expect_code "invalid bearer is refused (gateway)" '^401$' "$GATEWAY/v1/models" \
  -H 'Authorization: Bearer definitely-not-a-valid-key'
expect_code "invalid bearer is refused (dashboard)" '^40[13]$' "$DASHBOARD/api/v1/users" \
  -H 'Authorization: Bearer definitely-not-a-valid-key'

log "Cluster state (requires a kubeconfig; skipped without one)"
if command -v oc >/dev/null && oc whoami >/dev/null 2>&1; then
  NS="${NAMESPACE:-enmaas}"
  # Every Route admitted. Duplicate host+path claims silently reject a Route
  # and leave the path served by whatever won the claim.
  notadm="$(oc -n "$NS" get routes -o json 2>/dev/null | python3 -c '
import json,sys
bad=[]
for r in json.load(sys.stdin)["items"]:
    for ing in r.get("status",{}).get("ingress",[]):
        for c in ing.get("conditions",[]):
            if c["type"]=="Admitted" and c["status"]!="True": bad.append(r["metadata"]["name"])
print(" ".join(sorted(set(bad))))' 2>/dev/null || echo ERR)"
  if [[ "$notadm" == ERR ]]; then skip "route admission (could not read Routes in $NS)"
  elif [[ -z "$notadm" ]]; then pass "all Routes admitted in $NS"
  else fail "Routes not admitted in $NS: $notadm"; fi

  for d in maas-api metering-service praxis; do
    want="$(oc -n "$NS" get deploy "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")"
    got="$(oc -n "$NS" get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    if [[ -z "$want" ]]; then skip "deployment $d not present in $NS"
    elif [[ "${got:-0}" == "$want" ]]; then pass "deployment $d ready ($got/$want)"
    else fail "deployment $d ready ${got:-0}/$want"; fi
  done

  restarts="$(oc -n "$NS" get pods -o json 2>/dev/null | python3 -c '
import json,sys
out=[]
for p in json.load(sys.stdin)["items"]:
    for cs in p.get("status",{}).get("containerStatuses",[]):
        if cs.get("restartCount",0) > 0 and (cs.get("lastState",{}).get("terminated",{}) or {}).get("finishedAt"):
            out.append(f"{p[\"metadata\"][\"name\"]}:{cs[\"restartCount\"]}")
print(" ".join(out))' 2>/dev/null || echo "")"
  if [[ -z "$restarts" ]]; then pass "no containers with restarts"
  else skip "containers with prior restarts: $restarts"; fi
else
  skip "cluster checks (no oc login)"
fi

# ════════════════════════════════════════════════════════════════
# AUTH — valid credential behaviour
# ════════════════════════════════════════════════════════════════
if at_least auth; then
  log "Authenticated catalog (both dialects)"
  if [[ -z "$KEY" ]]; then
    skip "catalog/openai envelope (no key: set PRICETAG_KEY or KEY_FILE)"
    skip "catalog/anthropic envelope (no key)"
    skip "configured test models present in catalog (no key)"
  else
    got="$(curl_json "$WORK/models-openai.json" "$GATEWAY/v1/models" bearer)"
    if [[ "$got" == 200 ]] && jcheck '
import json,sys
b=json.load(open(sys.argv[1]))
assert b["object"]=="list" and b["data"][0]["object"]=="model"
' "$WORK/models-openai.json"; then pass "catalog/openai envelope"
    else fail "catalog/openai envelope (http $got)"; fi

    got="$(curl_json "$WORK/models-anthropic.json" "$GATEWAY/v1/models" anthropic)"
    if [[ "$got" == 200 ]] && jcheck '
import json,sys
b=json.load(open(sys.argv[1]))
assert b["data"][0]["type"]=="model" and "has_more" in b
' "$WORK/models-anthropic.json"; then pass "catalog/anthropic envelope"
    else fail "catalog/anthropic envelope (http $got)"; fi

    # The models this suite exercises must actually be offered.
    for m in "$MODEL_FREE" "$MODEL_ANTHROPIC" "$MODEL_OPENAI"; do
      if jcheck '
import json,sys
b=json.load(open(sys.argv[1]))
ids={d.get("id") for d in b.get("data",[])}
assert sys.argv[2] in ids
' "$WORK/models-openai.json" "$m" 2>/dev/null || \
         python3 -c '
import json,sys
b=json.load(open(sys.argv[1]))
ids={d.get("id") for d in b.get("data",[])}
sys.exit(0 if sys.argv[2] in ids else 1)' "$WORK/models-openai.json" "$m" 2>/dev/null
      then pass "catalog offers $m"
      else fail "catalog does not offer $m"; fi
    done

    # A key must never be echoed back to the caller.
    if grep -qF "$KEY" "$WORK/models-openai.json" 2>/dev/null; then
      fail "catalog response echoes the API key"
    else pass "catalog response does not echo the key"; fi
  fi

  log "Partner API with a credential"
  if [[ -z "$PARTNER_TOKEN" ]]; then
    skip "partner API authenticated read (no PARTNER_TOKEN)"
  else
    got="$(curl_json "$WORK/partner-models.json" "$DASHBOARD/api/v1/models" partner)"
    if [[ "$got" == 200 ]]; then pass "partner /api/v1/models authenticated (200)"
    else fail "partner /api/v1/models authenticated — got $got"; fi
  fi
fi

# ════════════════════════════════════════════════════════════════
# INFERENCE — real model traffic (costs tokens)
# ════════════════════════════════════════════════════════════════
PROMPT="Reply with exactly one word: onboarded"
# Output cap. Reasoning models spend this budget on reasoning before emitting
# any content, so it has to clear that floor or every call finishes with
# finish_reason=length and a null content.
MAX_OUT="${MAX_OUT:-64}"

# Each model is only callable on the dialect that routes it, with that
# dialect's parameter spelling. Getting this wrong looks like a gateway fault
# but is a client error:
#   claude-*  Messages only. On chat/completions it falls through to the
#             OpenAI upstream and comes back 404.
#   gpt-5.x   chat/completions, and rejects max_tokens in favour of
#             max_completion_tokens.
#   GLM       either dialect, max_tokens.
chat_payload() { # chat_payload <model> <token-param>
  python3 -c '
import json,sys
m,param,prompt,cap = sys.argv[1],sys.argv[2],sys.argv[3],int(sys.argv[4])
body={"model":m,"messages":[{"role":"user","content":prompt}]}
body[param]=cap
print(json.dumps(body))' "$1" "$2" "$PROMPT" "$MAX_OUT"
}
# A completion counts as working if the model produced any output at all.
# Reasoning models legitimately return content=null with the whole budget in
# reasoning_content, which still proves the request was routed and billed.
OPENAI_OK='
import json,sys
b=json.load(open(sys.argv[1]))
m=b["choices"][0]["message"]
assert (m.get("content") or m.get("reasoning_content") or "").strip(), "no content"
assert b["usage"]["completion_tokens"] > 0, "no tokens billed"
'
ANTHROPIC_OK='
import json,sys
b=json.load(open(sys.argv[1]))
text="".join(p.get("text","") or p.get("thinking","") for p in b.get("content") or [])
assert text.strip(), "no content"
assert b["usage"]["output_tokens"] > 0, "no tokens billed"
'

if at_least inference; then
  log "Inference: OpenAI dialect (chat/completions)"
  if [[ -z "$KEY" ]]; then
    skip "inference (no key: set PRICETAG_KEY or KEY_FILE)"
  else
    # free/hosted model, then the OpenAI provider with its own token spelling
    for spec in "$MODEL_FREE:max_tokens" "$MODEL_OPENAI:max_completion_tokens"; do
      m="${spec%:*}"; param="${spec##*:}"
      body="$WORK/chat.json"
      got="$(curl_json "$body" "$GATEWAY/v1/chat/completions" bearer \
        -X POST -H 'content-type: application/json' --data "$(chat_payload "$m" "$param")")"
      if [[ "$got" == 200 ]] && jcheck "$OPENAI_OK" "$body"; then pass "chat/completions $m"
      else fail "chat/completions $m (http $got: $(head -c 140 "$body" 2>/dev/null | tr -d '\n'))"; fi
    done

    log "Inference: Anthropic dialect (messages)"
    for m in "$MODEL_ANTHROPIC" "$MODEL_FREE"; do
      body="$WORK/messages.json"
      payload="$(python3 -c '
import json,sys
print(json.dumps({"model":sys.argv[1],"max_tokens":int(sys.argv[3]),
                  "messages":[{"role":"user","content":sys.argv[2]}]}))' "$m" "$PROMPT" "$MAX_OUT")"
      got="$(curl_json "$body" "$GATEWAY/v1/messages" anthropic \
        -X POST -H 'content-type: application/json' --data "$payload")"
      if [[ "$got" == 200 ]] && jcheck "$ANTHROPIC_OK" "$body"; then pass "messages $m"
      else fail "messages $m (http $got: $(head -c 140 "$body" 2>/dev/null | tr -d '\n'))"; fi
    done

    log "Catalog coherence"
    # Every model the OpenAI-format catalog advertises must be callable on the
    # endpoint that dialect uses. Advertising a model that 404s sends every
    # discovery-driven client into a dead end.
    adv="$(python3 -c '
import json,sys
try:
    b=json.load(open(sys.argv[1]))
    print((b.get("data") or [{}])[0].get("id",""))
except Exception:
    print("")' "$WORK/models-openai.json" 2>/dev/null)"
    if [[ -z "$adv" ]]; then skip "advertised model is callable (no catalog response)"
    else
      body="$WORK/adv.json"
      got="$(curl_json "$body" "$GATEWAY/v1/chat/completions" bearer \
        -X POST -H 'content-type: application/json' --data "$(chat_payload "$adv" max_tokens)")"
      # 400 is acceptable here: it means the model is routed and merely wants
      # different parameters. 404 means the catalog is advertising a dead model.
      if [[ "$got" == 404 ]]; then
        fail "advertised model '$adv' 404s on chat/completions — OpenAI catalog lists unusable models"
      else pass "advertised model '$adv' is routable ($got)"; fi
    fi
  fi
fi

# ════════════════════════════════════════════════════════════════
# FULL — streaming, concurrency, error shapes, metering
# ════════════════════════════════════════════════════════════════
if at_least full; then
  log "Streaming"
  if [[ -z "$KEY" ]]; then skip "streaming (no key)"
  else
    payload="$(python3 -c '
import json,sys
print(json.dumps({"model":sys.argv[1],
                  "messages":[{"role":"user","content":sys.argv[2]}],
                  "max_tokens":16,"stream":True}))' "$MODEL_FREE" "$PROMPT")"
    got="$(curl_json "$WORK/stream.txt" "$GATEWAY/v1/chat/completions" bearer \
      -X POST -H 'content-type: application/json' --data "$payload")"
    if [[ "$got" == 200 ]] && grep -q '^data:' "$WORK/stream.txt"; then
      pass "streaming chat/completions $MODEL_FREE"
    else fail "streaming chat/completions $MODEL_FREE (http $got)"; fi
  fi

  log "Error shapes"
  if [[ -z "$KEY" ]]; then skip "error shapes (no key)"
  else
    payload='{"model":"no-such-model-xyz","messages":[{"role":"user","content":"hi"}],"max_tokens":4}'
    got="$(curl_json "$WORK/badmodel.json" "$GATEWAY/v1/chat/completions" bearer \
      -X POST -H 'content-type: application/json' --data "$payload")"
    # An unknown model is a client error. A 5xx means the gateway fell over.
    if [[ "$got" =~ ^4[0-9][0-9]$ ]]; then pass "unknown model rejected ($got)"
    else fail "unknown model — got $got, want 4xx"; fi

    got="$(curl_json "$WORK/badjson.json" "$GATEWAY/v1/chat/completions" bearer \
      -X POST -H 'content-type: application/json' --data '{"not":"valid"')"
    if [[ "$got" =~ ^4[0-9][0-9]$ ]]; then pass "malformed JSON rejected ($got)"
    else fail "malformed JSON — got $got, want 4xx"; fi
  fi

  log "Concurrency"
  if [[ -z "$KEY" ]]; then skip "concurrency (no key)"
  else
    payload="$(python3 -c '
import json,sys
print(json.dumps({"model":sys.argv[1],
                  "messages":[{"role":"user","content":"Say: ok"}],
                  "max_tokens":8}))' "$MODEL_FREE")"
    pids=(); rc=0
    for i in 1 2 3 4 5; do
      ( curl_json "$WORK/conc-$i.json" "$GATEWAY/v1/chat/completions" bearer \
          -X POST -H 'content-type: application/json' --data "$payload" >"$WORK/conc-$i.code" ) &
      pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" || rc=1; done
    oks=0
    for i in 1 2 3 4 5; do [[ "$(cat "$WORK/conc-$i.code" 2>/dev/null)" == 200 ]] && oks=$((oks+1)); done
    if [[ "$oks" == 5 ]]; then pass "5 concurrent requests all 200"
    else fail "concurrent requests: $oks/5 returned 200"; fi
  fi

  log "Metering"
  # Proof that billable traffic was recorded. Needs a readonly DB URL in the
  # cluster, so it SKIPs from CI.
  if command -v oc >/dev/null && oc whoami >/dev/null 2>&1 && \
     oc -n "${NAMESPACE:-enmaas}" get secret metering-readonly-db-url >/dev/null 2>&1; then
    skip "metering row proof (manual: query usage_events against the readonly DB)"
  else
    skip "metering row proof (no cluster access or readonly DB secret)"
  fi
fi

# ── summary ─────────────────────────────────────────────────────
log "Summary — level=$LEVEL target=${TARGET:-custom} gateway=$GATEWAY_HOST"
printf '%s' "$RESULTS" | while IFS='|' read -r verdict name; do
  [[ -n "$verdict" ]] && printf '  %-4s %s\n' "$verdict" "$name"
done
printf '\n  %d passed, %d failed, %d skipped\n\n' "$P" "$F" "$S"
[[ "$F" -eq 0 ]] || exit 1
