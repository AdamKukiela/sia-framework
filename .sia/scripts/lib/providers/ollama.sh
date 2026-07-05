#!/usr/bin/env bash
# SIA Ollama Provider

# Variables inherited:
#   SIA_ACTIVE_MODEL, SIA_ACTIVE_BASE_URL, SIA_ACTIVE_TEMPERATURE, SIA_ACTIVE_NUM_CTX

BASE_URL="${SIA_ACTIVE_BASE_URL:-http://localhost:11434}"

# Call Ollama API using Python for robust payload construction and JSON extraction
python3 -c '
import sys, json, urllib.request

prompt = sys.stdin.read()
model = sys.argv[1]
base_url = sys.argv[2]
temp = float(sys.argv[3])
ctx = int(sys.argv[4])

url = f"{base_url.rstrip(\"/\")}/api/generate"
payload = {
    "model": model,
    "prompt": prompt,
    "stream": False,
    "options": {
        "num_ctx": ctx,
        "temperature": temp
    }
}

req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"}
)

try:
    with urllib.request.urlopen(req, timeout=300) as response:
        res = json.loads(response.read().decode("utf-8"))
        print(res.get("response", ""))
except Exception as e:
    print(f"ERROR: Ollama API call failed: {e}", file=sys.stderr)
    sys.exit(3)
' "$SIA_ACTIVE_MODEL" "$BASE_URL" "$SIA_ACTIVE_TEMPERATURE" "$SIA_ACTIVE_NUM_CTX"
