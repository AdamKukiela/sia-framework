#!/usr/bin/env bash
# SIA OpenAI Provider

# Variables inherited:
#   SIA_ACTIVE_MODEL, SIA_ACTIVE_BASE_URL, SIA_ACTIVE_TEMPERATURE, SIA_ACTIVE_MAX_TOKENS, SIA_ACTIVE_API_KEY_ENV

API_KEY_VAR="${SIA_ACTIVE_API_KEY_ENV:-OPENAI_API_KEY}"
API_KEY="${!API_KEY_VAR:-}"
BASE_URL="${SIA_ACTIVE_BASE_URL:-https://api.openai.com/v1}"

# For official OpenAI, key is required. For local providers, it might not be.
# If base_url is official openai, but no key is present, warn/fail.
if [[ "$BASE_URL" == *"api.openai.com"* && -z "$API_KEY" ]]; then
  echo "ERROR: OpenAI API Key not found in environment variable '$API_KEY_VAR'!" >&2
  exit 3
fi

python3 -c '
import sys, json, urllib.request

prompt = sys.stdin.read()
model = sys.argv[1]
api_key = sys.argv[2]
base_url = sys.argv[3]
temp = float(sys.argv[4])
max_tok = int(sys.argv[5])

url = f"{base_url.rstrip(\"/\")}/chat/completions"
headers = {
    "content-type": "application/json"
}
if api_key:
    headers["authorization"] = f"Bearer {api_key}"

payload = {
    "model": model,
    "messages": [
        {"role": "user", "content": prompt}
    ]
}

# Adjust parameters for reasoning models (o1/o3)
is_reasoning_model = model.startswith("o1-") or model.startswith("o3-") or model == "o1"
if is_reasoning_model:
    # o1/o3 models do not support standard temperature and use max_completion_tokens
    payload["max_completion_tokens"] = max_tok
else:
    payload["max_tokens"] = max_tok
    payload["temperature"] = temp

req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode("utf-8"),
    headers=headers
)

try:
    with urllib.request.urlopen(req, timeout=300) as response:
        res = json.loads(response.read().decode("utf-8"))
        choices = res.get("choices", [])
        if choices and len(choices) > 0:
            print(choices[0].get("message", {}).get("content", ""))
        else:
            print(f"ERROR: Invalid OpenAI API response: {res}", file=sys.stderr)
            sys.exit(3)
except Exception as e:
    print(f"ERROR: OpenAI API call failed: {e}", file=sys.stderr)
    sys.exit(3)
' "$SIA_ACTIVE_MODEL" "$API_KEY" "$BASE_URL" "$SIA_ACTIVE_TEMPERATURE" "$SIA_ACTIVE_MAX_TOKENS"
