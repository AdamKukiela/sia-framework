#!/usr/bin/env bash
# SIA Common Library

# Determine directories
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$LIB_DIR/../../.." && pwd)"

# Logger helper
sia_log() {
  echo "[$TASK] $*"
}

sia_err() {
  echo "[$TASK] ERROR: $*" >&2
}

# 1. Load config helper using inline python for robust parsing and compatibility
sia_load_config() {
  local config_file="${PROJECT_ROOT}/.sia/sia.json"
  if [[ ! -f "$config_file" ]]; then
    config_file="${PROJECT_ROOT}/sia.json"
  fi
  
  if [[ ! -f "$config_file" ]]; then
    echo "ERROR: Configuration file sia.json not found in .sia/ or project root!" >&2
    exit 3
  fi
  
  # Use heredoc to pass python code cleanly without shell expansion/parenthesis bugs
  local config_env
  config_env=$(python3 - "$config_file" << 'EOF'
import json, sys, os
config_path = sys.argv[1]
try:
    with open(config_path, "r") as f:
        cfg = json.load(f)
except Exception as e:
    print(f"echo ERROR: Failed to parse sia.json: {e} >&2; exit 2")
    sys.exit(2)

version = cfg.get("version", 1)
providers = cfg.get("providers", {})
commands = cfg.get("commands", {})
roles = cfg.get("roles", {})
run = cfg.get("run", {})
sandbox = cfg.get("sandbox", {})
context = cfg.get("context", {})
paths = cfg.get("paths", {})
forbidden_patterns = cfg.get("forbidden_patterns", [])
exclude_dirs = cfg.get("exclude_dirs", [])

# Fallback for V1 config
if version == 1 or not providers:
    legacy_provider = cfg.get("provider", "ollama")
    legacy_model = cfg.get("model", "qwen2.5-coder:14b")
    legacy_base_url = cfg.get("ollama_url", "http://localhost:11434")
    legacy_ctx = cfg.get("num_ctx", 16384)
    legacy_temp = cfg.get("temperature", 0.2)
    
    providers["default"] = {
        "provider": legacy_provider,
        "model": legacy_model,
        "base_url": legacy_base_url,
        "num_ctx": legacy_ctx,
        "temperature": legacy_temp
    }
    roles = {
        "worker": "default",
        "architect": "default",
        "review": "default"
    }

# Export schema version
print("export SIA_VERSION=" + str(version))

# Export role maps
for role, prov in roles.items():
    print(f"export SIA_ROLE_{role.upper()}={json.dumps(prov)}")

# Export providers config
for p_name, p_cfg in providers.items():
    p_name_clean = p_name.upper().replace("-", "_")
    p_prefix = f"SIA_PROVIDER_{p_name_clean}_"
    print(f"export {p_prefix}PROVIDER={json.dumps(p_cfg.get('provider', ''))}")
    print(f"export {p_prefix}MODEL={json.dumps(p_cfg.get('model', ''))}")
    print(f"export {p_prefix}CMD={json.dumps(p_cfg.get('cmd', ''))}")
    print(f"export {p_prefix}BASE_URL={json.dumps(p_cfg.get('base_url', ''))}")
    print(f"export {p_prefix}NUM_CTX={p_cfg.get('num_ctx', 16384)}")
    print(f"export {p_prefix}TEMPERATURE={p_cfg.get('temperature', 0.2)}")
    print(f"export {p_prefix}MAX_TOKENS={p_cfg.get('max_tokens', 4096)}")
    print(f"export {p_prefix}API_KEY_ENV={json.dumps(p_cfg.get('api_key_env', ''))}")

# Export commands
print(f"export SIA_CMD_TEST={json.dumps(commands.get('test', ''))}")
print(f"export SIA_CMD_LINT={json.dumps(commands.get('lint', ''))}")
print(f"export SIA_CMD_FORMAT={json.dumps(commands.get('format', ''))}")

# Export run options
print(f"export SIA_RUN_MAX_ATTEMPTS={run.get('max_attempts', 3)}")
print(f"export SIA_RUN_TOTAL_TIMEOUT_SEC={run.get('total_timeout_sec', 1800)}")
print(f"export SIA_RUN_COMMAND_TIMEOUT_SEC={run.get('command_timeout_sec', 600)}")
print(f"export SIA_RUN_FEEDBACK_HEAD_LINES={run.get('feedback_head_lines', 30)}")
print(f"export SIA_RUN_FEEDBACK_TAIL_LINES={run.get('feedback_tail_lines', 120)}")
print(f"export SIA_RUN_DEFAULT_MODE={json.dumps(run.get('default_mode', 'worker'))}")

# Export sandbox settings
print(f"export SIA_SANDBOX_MODE={json.dumps(sandbox.get('mode', 'none'))}")
print(f"export SIA_SANDBOX_DOCKER_IMAGE={json.dumps(sandbox.get('docker_image', ''))}")

# Export context settings
print(f"export SIA_CONTEXT_REPO_MAP={str(context.get('repo_map', True)).lower()}")
print(f"export SIA_CONTEXT_REPO_MAP_MAX_FILES={context.get('repo_map_max_files', 400)}")
print(f"export SIA_CONTEXT_BUDGET_PCT={context.get('budget_pct', 80)}")

# Export arrays
print(f"export SIA_FORBIDDEN_PATTERNS={json.dumps(' '.join(forbidden_patterns))}")
print(f"export SIA_EXCLUDE_DIRS={json.dumps(' '.join(exclude_dirs))}")

# Export paths
print(f"export SIA_PATH_BRAIN_DIR={json.dumps(paths.get('brain_dir', '.brain'))}")
print(f"export SIA_PATH_TASKS_DIR={json.dumps(paths.get('tasks_dir', '.brain/tasks'))}")
print(f"export SIA_PATH_WORKER_DIR={json.dumps(paths.get('worker_dir', '.worker'))}")
print(f"export SIA_PATH_RUNS_DIR={json.dumps(paths.get('runs_dir', '.worker/runs'))}")
print(f"export SIA_PATH_ESCALATIONS_DIR={json.dumps(paths.get('escalations_dir', '.worker/escalations'))}")
EOF
)

  eval "$config_env"
}

# 2. Get active provider config details for a specific role
sia_get_role_provider_env() {
  local role="$1"
  local role_upper
  role_upper=$(echo "$role" | tr '[:lower:]' '[:upper:]')
  
  # Get provider name mapped to this role
  local prov_var="SIA_ROLE_${role_upper}"
  local prov_name="${!prov_var:-}"
  
  if [[ "$role" == "worker" && -n "${SIA_MODEL_OVERRIDE:-}" ]]; then
    prov_name="$SIA_MODEL_OVERRIDE"
  fi
  
  if [[ -z "$prov_name" ]]; then
    # Fallback to default or the first provider if not set
    prov_name="default"
  fi
  
  local prov_upper
  prov_upper=$(echo "$prov_name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
  
  # Map variables
  local p_provider_var="SIA_PROVIDER_${prov_upper}_PROVIDER"
  local p_model_var="SIA_PROVIDER_${prov_upper}_MODEL"
  local p_cmd_var="SIA_PROVIDER_${prov_upper}_CMD"
  local p_base_url_var="SIA_PROVIDER_${prov_upper}_BASE_URL"
  local p_num_ctx_var="SIA_PROVIDER_${prov_upper}_NUM_CTX"
  local p_temp_var="SIA_PROVIDER_${prov_upper}_TEMPERATURE"
  local p_max_tok_var="SIA_PROVIDER_${prov_upper}_MAX_TOKENS"
  local p_api_env_var="SIA_PROVIDER_${prov_upper}_API_KEY_ENV"
  
  export SIA_ACTIVE_PROVIDER="${!p_provider_var:-}"
  export SIA_ACTIVE_MODEL="${!p_model_var:-}"
  export SIA_ACTIVE_CMD="${!p_cmd_var:-}"
  export SIA_ACTIVE_BASE_URL="${!p_base_url_var:-}"
  export SIA_ACTIVE_NUM_CTX="${!p_num_ctx_var:-16384}"
  export SIA_ACTIVE_TEMPERATURE="${!p_temp_var:-0.2}"
  export SIA_ACTIVE_MAX_TOKENS="${!p_max_tok_var:-4096}"
  export SIA_ACTIVE_API_KEY_ENV="${!p_api_env_var:-}"
}

# 3. Parsing markdown section (e.g. ## Scope) using Python for robustness
sia_parse_section() {
  local section_name="$1"
  local file_path="$2"
  
  python3 -c '
import sys, re
section = sys.argv[1].lower()
filepath = sys.argv[2]

try:
    with open(filepath, "r") as f:
        lines = f.readlines()
except Exception as e:
    sys.exit(1)

in_section = False
output = []
for line in lines:
    clean_line = line.strip()
    if clean_line.startswith("##"):
        # Check if match section name
        match = re.match(r"^##\s*(.+)$", clean_line)
        if match:
            current_section = match.group(1).lower().strip()
            if current_section.startswith(section):
                in_section = True
                continue
            elif in_section:
                # Met another section header, stop
                break
    if in_section:
        # We are inside the section. Collect list items (- item)
        match_item = re.match(r"^-\s*(.+)$", clean_line)
        if match_item:
            item = match_item.group(1).split("<!--")[0].strip()
            if item:
                output.append(item)

for val in output:
    print(val)
' "$section_name" "$file_path"
}

# 4. Scope matching function (exact match or prefix only if scope_path ends with '/')
sia_in_scope() {
  local changed_file="$1"
  shift
  local scope_paths=("$@")
  
  for scope_path in "${scope_paths[@]}"; do
    if [[ "$scope_path" == */ ]]; then
      # Directory prefix match
      if [[ "$changed_file" == "$scope_path"* ]]; then
        return 0
      fi
    else
      # Exact file match
      if [[ "$changed_file" == "$scope_path" ]]; then
        return 0
      fi
    fi
  done
  return 1
}

# 5. Escalation writer helper
sia_write_escalation() {
  local task="$1"
  local exit_code="$2"
  local reason="$3"
  local attempts_dir="$PROJECT_ROOT/${SIA_PATH_RUNS_DIR}/${task}"
  local esc_file="$PROJECT_ROOT/${SIA_PATH_ESCALATIONS_DIR}/${task}.md"
  
  mkdir -p "$(dirname "$esc_file")"
  
  {
    echo "# Escalation: $task"
    echo "## Reason"
    echo "Exit code: $exit_code"
    echo "\`\`\`text"
    echo "$reason"
    echo "\`\`\`"
    echo ""
    echo "## Attempts"
    
    local idx=1
    for att_file in $(ls "$attempts_dir"/attempt-*.md 2>/dev/null | sort -V); do
      local att_name
      att_name=$(basename "$att_file")
      echo "${idx}. [${att_name}](file://${att_file}) — See runs directory for details."
      idx=$((idx + 1))
    done
    
    echo ""
    echo "## Suggested next step"
    echo "The Worker has encountered a logic error or a forbidden rule violation. Please review the run attempts and verify the task contract invariants or requirements."
  } > "$esc_file"
  
  sia_log "Escalation report written to: $esc_file"
}
