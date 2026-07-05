#!/usr/bin/env bash
set -e

echo "=== Installing SIA Framework ==="
echo ""

# Base repository URL (configurable, defaults to company organization)
BASE_URL="${SIA_REPO_URL:-https://raw.githubusercontent.com/AdamKukiela/sia-framework/main}"

# Helper function for interactive multi-select checkbox menu in Bash
prompt_checklist() {
  local title="$1"
  local dest_var="$2"
  shift 2
  
  local options=()
  local states=()
  while [[ $# -gt 0 ]]; do
    options+=("$1")
    states+=("$2")
    shift 2
  done
  
  local num_options=${#options[@]}
  local active=0
  
  # Hide cursor
  tput civis
  
  # Helper to print the list
  print_checklist() {
    echo -e "\033[1m$title\033[0m"
    echo "  (Use Up/Down arrows to navigate, Space to select/deselect, Enter to confirm)"
    echo ""
    for ((i=0; i<num_options; i++)); do
      local marker="[ ]"
      if [[ "${states[i]}" == "true" ]]; then
        marker="[\033[32m*\033[0m]"
      fi
      
      if [[ $i -eq $active ]]; then
        echo -e " \033[1;36m>\033[0m $marker ${options[i]}"
      else
        echo -e "   $marker ${options[i]}"
      fi
    done
  }
  
  # Initial print
  print_checklist
  
  while true; do
    # Read user input (1 char)
    read -rsn1 key
    if [[ "$key" == $'\x1b' ]]; then
      # Read remaining escape sequence chars with a short timeout to prevent lockups
      read -rsn2 -t 0.1 key2
      if [[ "$key2" == "[A" ]]; then # Up arrow
        ((active--))
        [[ $active -lt 0 ]] && active=$((num_options - 1))
      elif [[ "$key2" == "[B" ]]; then # Down arrow
        ((active++))
        [[ $active -ge $num_options ]] && active=0
      fi
    elif [[ "$key" == "" ]]; then # Enter
      break
    elif [[ "$key" == " " ]]; then # Space
      if [[ "${states[active]}" == "true" ]]; then
        states[active]="false"
      else
        states[active]="true"
      fi
    fi
    
    # Move cursor back up to redraw the menu cleanly
    for ((i=0; i<=num_options+2; i++)); do
      tput cuu1
      tput el
    done
    print_checklist
  done
  
  # Restore cursor
  tput cnorm
  
  # Export results as array string
  local results=""
  for ((i=0; i<num_options; i++)); do
    results+="${states[i]} "
  done
  eval "$dest_var=($results)"
}

# 1. Interactive configuration wizard (DX) or Non-interactive default configuration
interactive=0
if [[ -c /dev/tty ]]; then
  exec < /dev/tty
  interactive=1

  echo "--------------------------------------------------------"
  echo "🤖 Welcome to the SIA Interactive Configuration Wizard!"
  echo "SIA safely delegates coding tasks to AI models."
  echo "Let's configure your local directories and AI provider."
  echo "--------------------------------------------------------"
  echo ""

  # Task folder setup
  echo ">> 1. AI Task Contracts Folder"
  echo "Where should we store your AI task contracts (definitions of done, scopes, rules)?"
  echo "(If you do not have a second-brain/Obsidian vault, press Enter to create a default folder)"
  read -rp "Folder name [default: .sia]: " input_brain
  brain_dir="${input_brain:-.sia}"
  tasks_dir="${brain_dir}/tasks"
  wiki_dir="${brain_dir}/wiki"
  echo "-> Tasks folder will be: ${tasks_dir}"
  echo ""

  # Worker runs folder setup
  echo ">> 2. Worker Run logs & Escalations Folder"
  echo "Where should we store worker execution logs, intermediate runs, and escalations?"
  echo "(Recommended: Press Enter to use the default, unless you already have a folder for temporary run logs)"
  read -rp "Folder name [default: .sia-worker]: " input_worker
  worker_dir="${input_worker:-.sia-worker}"
  runs_dir="${worker_dir}/runs"
  escalations_dir="${worker_dir}/escalations"
  echo "-> Runs folder will be: ${runs_dir}"
  echo ""

  # Create directories
  mkdir -p "$tasks_dir" "$wiki_dir" "$runs_dir" "$escalations_dir"

  # Provider selection via checkbox checklist
  echo ">> 3. Worker Model Provider"
  declare -a p_choices
  prompt_checklist "Select which AI providers you have available and want to configure:" p_choices \
    "Ollama (Local, default: qwen2.5-coder:14b) [Recommended]" "true" \
    "Anthropic API (Claude 5 Sonnet / Haiku 4.5)" "false" \
    "OpenAI API (GPT-5.5-preview / GPT-5.4 mini)" "false" \
    "Subscription CLI (claude code / agy / codex / custom)" "false" \
    "Google Gemini API (gemini-2.5-flash / gemini-2.5-pro)" "false"

  echo "Selected options: ${p_choices[*]}"
  echo ""

  # Commands selection
  echo ">> 4. Project Commands"
  read -rp "Enter your project's unit testing command [default: npm test]: " test_cmd
  test_cmd="${test_cmd:-npm test}"

  read -rp "Enter your project's linter command [default: npx eslint --format compact]: " lint_cmd
  lint_cmd="${lint_cmd:-npx eslint --format compact}"
  echo ""

  # Generate sia.json dynamically with selected providers
  echo "Writing customized sia.json..."
  python3 -c '
import json, sys

selected_ollama = sys.argv[3] == "true"
selected_anthropic = sys.argv[4] == "true"
selected_openai = sys.argv[5] == "true"
selected_cli = sys.argv[6] == "true"
selected_google = sys.argv[7] == "true"

test_cmd = sys.argv[8]
lint_cmd = sys.argv[9]
brain_dir = sys.argv[10]
worker_dir = sys.argv[11]

# Base structure
data = {
  "version": 2,
  "providers": {},
  "roles": {
    "worker": "",
    "architect": "",
    "review": ""
  },
  "paths": {
    "brain_dir": brain_dir,
    "tasks_dir": brain_dir + "/tasks",
    "worker_dir": worker_dir,
    "runs_dir": worker_dir + "/runs",
    "escalations_dir": worker_dir + "/escalations"
  },
  "run": {
    "max_attempts": 3,
    "total_timeout_sec": 1800,
    "command_timeout_sec": 600,
    "feedback_head_lines": 30,
    "feedback_tail_lines": 120,
    "default_mode": "worker"
  },
  "sandbox": {
    "mode": "none",
    "docker_image": "node:20"
  },
  "context": {
    "repo_map": True,
    "repo_map_max_files": 400,
    "budget_pct": 80
  },
  "commands": {
    "test": test_cmd,
    "lint": lint_cmd,
    "format": "npx prettier --write"
  },
  "forbidden_patterns": [
    "as unknown as",
    "@ts-ignore",
    "@ts-nocheck",
    "eslint-disable",
    "[.]skip[(]",
    "describe[.]skip",
    "it[.]skip",
    "test[.]skip",
    ": any$",
    ": any[^a-zA-Z]",
    "catch[[:space:]]*[{][[:space:]]*[}]"
  ],
  "exclude_dirs": [
    "node_modules",
    "dist",
    ".git",
    brain_dir,
    worker_dir
  ]
}

# Add selected providers
default_worker = ""
default_architect = ""

if selected_ollama:
    data["providers"]["local-worker"] = {
        "provider": "ollama",
        "model": "qwen2.5-coder:14b",
        "base_url": "http://localhost:11434",
        "temperature": 0.2
    }
    if not default_worker: default_worker = "local-worker"

if selected_anthropic:
    data["providers"]["claude-api"] = {
        "provider": "anthropic",
        "model": "claude-5-sonnet",
        "max_tokens": 8192,
        "api_key_env": "ANTHROPIC_API_KEY",
        "temperature": 0.2
    }
    if not default_worker: default_worker = "claude-api"
    if not default_architect: default_architect = "claude-api"

if selected_openai:
    data["providers"]["openai-api"] = {
        "provider": "openai",
        "model": "gpt-5.5-preview",
        "max_tokens": 4096,
        "api_key_env": "OPENAI_API_KEY",
        "temperature": 0.2
    }
    if not default_worker: default_worker = "openai-api"
    if not default_architect: default_architect = "openai-api"

if selected_cli:
    data["providers"]["claude-cli"] = {
        "provider": "cli",
        "model": "claude"
    }
    if not default_worker: default_worker = "claude-cli"

if selected_google:
    data["providers"]["gemini-api"] = {
        "provider": "google",
        "model": "gemini-2.5-flash",
        "max_tokens": 8192,
        "api_key_env": "GEMINI_API_KEY",
        "temperature": 0.2
    }
    if not default_worker: default_worker = "gemini-api"
    if not default_architect: default_architect = "gemini-api"

# Fallback defaults if none selected
if not default_worker:
    data["providers"]["local-worker"] = {
        "provider": "ollama",
        "model": "qwen2.5-coder:14b",
        "base_url": "http://localhost:11434",
        "temperature": 0.2
    }
    default_worker = "local-worker"

if not default_architect:
    if "claude-api" in data["providers"]:
        default_architect = "claude-api"
    else:
        default_architect = default_worker

# Set roles
data["roles"]["worker"] = default_worker
data["roles"]["architect"] = default_architect
data["roles"]["review"] = default_architect

with open("sia.json", "w") as f:
    json.dump(data, f, indent=2)
' "$brain_dir" "$worker_dir" \
  "${p_choices[0]}" "${p_choices[1]}" "${p_choices[2]}" "${p_choices[3]}" "${p_choices[4]}" \
  "$test_cmd" "$lint_cmd" "$brain_dir" "$worker_dir"

else
  # Non-interactive mode (e.g. CI or automated scripts) - fallback to silent default setup
  sia_json="sia.json"
  if [[ ! -f "$sia_json" ]]; then
    cp_default_sia=1
  fi
fi

# 2. Download all required scripts and templates
declare -a FILES=(
  ".sia/AGENTS.md"
  ".sia/scripts/sia-gate.sh"
  ".sia/scripts/sia-worker.sh"
  ".sia/scripts/sia-run.sh"
  ".sia/scripts/lib/common.sh"
  ".sia/scripts/lib/context.sh"
  ".sia/scripts/lib/run_cmd.py"
  ".sia/scripts/lib/sia_apply.py"
  ".sia/scripts/lib/context_builder.py"
  ".sia/scripts/lib/providers/ollama.sh"
  ".sia/scripts/lib/providers/anthropic.sh"
  ".sia/scripts/lib/providers/openai.sh"
  ".sia/scripts/lib/providers/google.sh"
  ".sia/scripts/lib/providers/cli.sh"
  ".sia/scripts/lib/providers/mock.sh"
  ".sia/templates/sia.json"
  ".sia/templates/TASK_TEMPLATE.md"
  ".sia/templates/sia.sb"
  ".sia/tests/run_tests.sh"
)

echo "Configuration completed. Downloading framework files..."
# Temporary directory creation inside .sia/
mkdir -p .sia/scripts/lib/providers .sia/templates .sia/tests

for file in "${FILES[@]}"; do
  url="${BASE_URL}/${file}"
  echo "Downloading ${file}..."
  set +e
  curl -fsS "$url" -o "$file"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "ERROR: Failed to download ${file} from ${url}" >&2
    exit 1
  fi
done

# Set executable permissions
chmod +x .sia/scripts/sia-gate.sh .sia/scripts/sia-worker.sh .sia/scripts/sia-run.sh
chmod +x .sia/scripts/lib/run_cmd.py .sia/scripts/lib/sia_apply.py .sia/tests/run_tests.sh

# 3. Post-download setup and success messages
if [[ $interactive -eq 1 ]]; then
  # Copy TASK_TEMPLATE to custom tasks dir
  cp .sia/templates/TASK_TEMPLATE.md "${tasks_dir}/TASK_TEMPLATE.md"

  echo ""
  echo "=== SIA Framework Initialized Successfully ==="
  echo "1. Verify sia.json in your project root."
  echo "2. Make sure your environment variables / subscriptions are set up."
  echo "3. Add your first task contract in ${tasks_dir}/TASK-001.md."
  echo "4. Run the orchestrator loop: ./.sia/scripts/sia-run.sh TASK-001"
else
  # Non-interactive setup completion
  if [[ "${cp_default_sia:-0}" -eq 1 ]]; then
    cp .sia/templates/sia.json "sia.json"
  fi
  mkdir -p .brain/tasks .brain/wiki .worker/runs .worker/escalations
  cp .sia/templates/TASK_TEMPLATE.md .brain/tasks/TASK_TEMPLATE.md
  
  echo "=== SIA Framework Initialized Successfully (Non-Interactive) ==="
  echo "Standard folders (.brain, .worker) created. Configuration copied to sia.json."
fi
