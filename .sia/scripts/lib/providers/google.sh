#!/usr/bin/env bash
# SIA Google Gemini Provider

# Variables inherited:
#   SIA_ACTIVE_MODEL, SIA_ACTIVE_TEMPERATURE, SIA_ACTIVE_MAX_TOKENS, SIA_ACTIVE_API_KEY_ENV

API_KEY_VAR="${SIA_ACTIVE_API_KEY_ENV:-GEMINI_API_KEY}"
API_KEY="${!API_KEY_VAR:-}"

if [[ -z "$API_KEY" ]]; then
  echo "ERROR: Gemini API Key not found in environment variable '$API_KEY_VAR'!" >&2
  exit 3
fi

python3 -c '
import sys, json, urllib.request

prompt = sys.stdin.read()
model = sys.argv[1]
api_key = sys.argv[2]
temp = float(sys.argv[3])
max_tok = int(sys.argv[4])

# Direct Gemini API Endpoint
url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={api_key}"
headers = {
    "content-type": "application/json"
}

payload = {
    "contents": [{
        "parts": [{
            "text": prompt
        }]
    }],
    "generationConfig": {
        "temperature": temp,
        "maxOutputTokens": max_tok
    }
}

req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode("utf-8"),
    headers=headers
)

try:
    with urllib.request.urlopen(req, timeout=300) as response:
        res = json.loads(response.read().decode("utf-8"))
        candidates = res.get("candidates", [])
        if not candidates:
            # Handle potential API errors returned in JSON
            if "error" in res:
                print(f"API Error: {res[\"error\"][\"message\"]}", file=sys.stderr)
            else:
                print(f"API Error: No generation candidates returned. Response: {res}", file=sys.stderr)
            sys.exit(1)
        
        parts = candidates[0].get("content", {}).get("parts", [])
        if parts and "text" in parts[0]:
            print(parts[0]["text"])
        else:
            print("API Error: No text found in candidate parts", file=sys.stderr)
            sys.exit(1)
except Exception as e:
    print(f"Request failed: {e}", file=sys.stderr)
    sys.exit(1)
' "$SIA_ACTIVE_MODEL" "$API_KEY" "${SIA_ACTIVE_TEMPERATURE:-0.2}" "${SIA_ACTIVE_MAX_TOKENS:-8192}"
