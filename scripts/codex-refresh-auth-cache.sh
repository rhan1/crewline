#!/usr/bin/env bash
# Decode ~/.codex/auth.json (JWT id_token) into a pipe-delimited cache file
# for fast read from the Claude Code statusline. Called lazily by the
# statusline when auth.json is newer than the cache, and eagerly by the
# dispatch wrapper after every codex invocation.
#
# Cache format (single line): email|plan|default-org

set -uo pipefail

AUTH_JSON="$HOME/.codex/auth.json"
CACHE="$HOME/.claude/codex-auth-cache.txt"

mkdir -p "$(dirname "$CACHE")"

if [ ! -f "$AUTH_JSON" ]; then
  echo "missing|none|none" > "$CACHE"
  exit 0
fi

python3 - > "$CACHE" <<'PY'
import json, base64, os, sys

def decode_jwt_payload(tok):
    try:
        payload = tok.split('.')[1]
        payload += '=' * ((4 - len(payload) % 4) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return None

try:
    with open(os.path.expanduser("~/.codex/auth.json")) as f:
        data = json.load(f)
except Exception:
    print("error|none|none")
    sys.exit(0)

tokens = (data or {}).get("tokens", {}) or {}
id_tok = tokens.get("id_token", "") or ""
payload = decode_jwt_payload(id_tok) if id_tok else None

if not payload:
    print("unknown|none|none")
    sys.exit(0)

email = payload.get("email") or "unknown"
ns = payload.get("https://api.openai.com/auth", {}) or {}
plan = ns.get("chatgpt_plan_type") or "unknown"
orgs = ns.get("organizations", []) or []
default_org = next((o for o in orgs if o.get("is_default")), orgs[0] if orgs else {})
org = default_org.get("title") or "unknown"
print(f"{email}|{plan}|{org}")
PY
