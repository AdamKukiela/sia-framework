#!/usr/bin/env bash
# SIA Anthropic Provider

# Variables inherited:
#   SIA_ACTIVE_MODEL, SIA_ACTIVE_TEMPERATURE, SIA_ACTIVE_MAX_TOKENS, SIA_ACTIVE_API_KEY_ENV

# Resolve API Key
API_KEY_VAR="${SIA_ACTIVE_API_KEY_ENV:-ANTHROPIC_API_KEY}"
API_KEY="${!API_KEY_VAR:-}"

if [[ -z "$API_KEY" ]]; then
  echo "ERROR: Anthropic API Key not found in environment variable '$API_KEY_VAR'!" >&2
  exit 3
fi

python3 -c '
import sys, json, urllib.request

prompt = sys.stdin.read()
model = sys.argv[1]
api_key = sys.argv[2]
temp = float(sys.argv[3])
max_tok = int(sys.argv[4])

url = "https://api.anthropic.com/v1/messages"
headers = {
    "x-api-key": api_key,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json"
}

payload = {
    "model": model,
    "max_tokens": max_tok,
    "temperature": temp,
    "messages": [
        {"role": "user", "content": prompt}
    ]
}

req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode("utf-8"),
    headers=headers
)

try:
    with urllib.request.urlopen(req, timeout=300) as response:
        res = json.loads(response.read().decode("utf-8"))
        # Parse content block
        content = res.get("content", [])
        if content and len(content) > 0:
            print(content[0].get("text", ""))
        else:
            print(f"ERROR: Invalid response structure: {res}", file=sys.stderr)
            sys.exit(3)
except Exception as e:
    print(f"ERROR: Anthropic API call failed: {e}", file=sys.stderr)
    sys.exit(3)
' "$SIA_ACTIVE_MODEL" "$API_KEY" "$SIA_ACTIVE_TEMPERATURE" "$SIA_ACTIVE_MAX_TOKENS"
