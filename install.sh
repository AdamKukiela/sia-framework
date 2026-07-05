#!/usr/bin/env bash
set -e

echo "=== Installing SIA Framework ==="
echo ""

# Base repository URL (configurable, defaults to company organization)
BASE_URL="${SIA_REPO_URL:-https://raw.githubusercontent.com/AdamKukiela/sia-framework/main}"

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
  read -rp "Folder name [default: .sia-worker]: " input_worker
  worker_dir="${input_worker:-.sia-worker}"
  runs_dir="${worker_dir}/runs"
  escalations_dir="${worker_dir}/escalations"
  echo "-> Runs folder will be: ${runs_dir}"
  echo ""

  # Create directories
  mkdir -p "$tasks_dir" "$wiki_dir" "$runs_dir" "$escalations_dir"

  # Provider selection
  echo ">> 3. Worker Model Provider"
  echo "Which AI provider will your Worker use?"
  echo "  1) Ollama (Local, default: qwen2.5-coder:14b) [Recommended]"
  echo "  2) Anthropic API (Claude 3.5 Haiku / 3.7 Sonnet)"
  echo "  3) OpenAI API (GPT-4o-mini / GPT-4o)"
  read -rp "Choose [1-3, default: 1]: " provider_choice
  provider_choice="${provider_choice:-1}"

  p_provider=""
  p_model=""
  p_base_url=""
  p_api_env=""

  if [[ "$provider_choice" == "2" ]]; then
    p_provider="anthropic"
    p_model="claude-3-5-haiku-20241022"
    p_api_env="ANTHROPIC_API_KEY"
  elif [[ "$provider_choice" == "3" ]]; then
    p_provider="openai"
    p_model="gpt-4o-mini"
    p_api_env="OPENAI_API_KEY"
  else
    p_provider="ollama"
    p_model="qwen2.5-coder:14b"
    p_base_url="http://localhost:11434"
  fi
  echo "-> Selected Provider: ${p_provider} (${p_model})"
  echo ""

  # Commands selection
  echo ">> 4. Project Commands"
  read -rp "Enter your project's unit testing command [default: npm test]: " test_cmd
  test_cmd="${test_cmd:-npm test}"

  read -rp "Enter your project's linter command [default: npx eslint --format compact]: " lint_cmd
  lint_cmd="${lint_cmd:-npx eslint --format compact}"
  echo ""

  # Generate sia.json
  echo "Writing customized sia.json..."
  python3 -c '
import json, sys
data = {
  "version": 2,
  "providers": {
    "local-worker": {
      "provider": sys.argv[3],
      "model": sys.argv[4],
      "temperature": 0.2
    },
    "claude-api": {
      "provider": "anthropic",
      "model": "claude-3-7-sonnet-20250219",
      "max_tokens": 8192,
      "api_key_env": "ANTHROPIC_API_KEY",
      "temperature": 0.2
    }
  },
  "roles": {
    "worker": "local-worker",
    "architect": "claude-api",
    "review": "claude-api"
  },
  "paths": {
    "brain_dir": sys.argv[1],
    "tasks_dir": sys.argv[1] + "/tasks",
    "worker_dir": sys.argv[2],
    "runs_dir": sys.argv[2] + "/runs",
    "escalations_dir": sys.argv[2] + "/escalations"
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
    "test": sys.argv[7],
    "lint": sys.argv[8],
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
    sys.argv[1],
    sys.argv[2]
  ]
}

# Add URL or API key env if specified
if sys.argv[5]:
    data["providers"]["local-worker"]["base_url"] = sys.argv[5]
if sys.argv[6]:
    data["providers"]["local-worker"]["api_key_env"] = sys.argv[6]

with open("sia.json", "w") as f:
    json.dump(data, f, indent=2)
' "$brain_dir" "$worker_dir" "$p_provider" "$p_model" "$p_base_url" "$p_api_env" "$test_cmd" "$lint_cmd"

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
  if [[ "$p_provider" == "ollama" ]]; then
    echo "2. Make sure Ollama is running and pull the model:"
    echo "   ollama pull ${p_model}"
  else
    echo "2. Make sure your environment variable '${p_api_env}' is set."
  fi
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
