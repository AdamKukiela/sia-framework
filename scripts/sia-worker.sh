#!/usr/bin/env bash
# SIA Worker — Agnostic implementation of a single attempt execution
# Usage: ./scripts/sia-worker.sh TASK-XXX [attempt] [--orchestrated]

set -euo pipefail

TASK="${1:-}"
ATTEMPT="${2:-1}"
ORCHESTRATED="${3:-}" # Or read from SIA_ORCHESTRATED

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source common and context helpers
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/lib/context.sh
source "$SCRIPT_DIR/lib/context.sh"

# Inicjalizacja konfiguracji
sia_load_config

# Resolve active mode (CLI flag overrides config default_mode)
ACTIVE_MODE="${SIA_RUN_MODE:-$SIA_RUN_DEFAULT_MODE}"
export SIA_RUN_MODE="$ACTIVE_MODE"

if [[ -z "$TASK" ]]; then
  sia_err "Usage: ./scripts/sia-worker.sh TASK-001 [attempt] [--orchestrated]"
  exit 1
fi

# Detect role based on mode
ROLE="worker"
if [[ "$ACTIVE_MODE" == "architect" ]]; then
  ROLE="architect"
elif [[ "$ACTIVE_MODE" == "review" ]]; then
  ROLE="review"
fi

# Load active provider configuration for the chosen role
sia_get_role_provider_env "$ROLE"

# Verify task file path
TASK_FILE="$PROJECT_ROOT/${SIA_PATH_TASKS_DIR}/${TASK}.md"
# For architect mode, the file might not exist yet if generating a new task
if [[ "$ACTIVE_MODE" != "architect" && ! -f "$TASK_FILE" ]]; then
  sia_err "Task file not found: $TASK_FILE"
  exit 1
fi

OUTPUT_DIR="$PROJECT_ROOT/${SIA_PATH_RUNS_DIR}/${TASK}"
mkdir -p "$OUTPUT_DIR"

# Resolve previous feedback path
FEEDBACK_FILE="$OUTPUT_DIR/feedback.txt"

# 1. Compile prompt using context builder
sia_log "Compiling prompt for mode '$ACTIVE_MODE' (Attempt $ATTEMPT)..."
PROMPT=$(sia_build_prompt "$TASK_FILE" "$ATTEMPT" "$SIA_RUN_MAX_ATTEMPTS" "$FEEDBACK_FILE")

# Dump prompt for debugging
PROMPT_DUMP_FILE="$OUTPUT_DIR/attempt-${ATTEMPT}-prompt.txt"
echo "$PROMPT" > "$PROMPT_DUMP_FILE"

# 2. Dispatch to provider script
sia_log "Dispatching to provider '$SIA_ACTIVE_PROVIDER' (model '$SIA_ACTIVE_MODEL')..."

PROVIDER_SCRIPT="$SCRIPT_DIR/lib/providers/${SIA_ACTIVE_PROVIDER}.sh"
if [[ ! -f "$PROVIDER_SCRIPT" ]]; then
  sia_err "Provider script not found: $PROVIDER_SCRIPT"
  exit 3
fi

# Set attempt for providers (e.g. mock provider uses it)
export SIA_ATTEMPT="$ATTEMPT"

set +e
RESPONSE=$(echo "$PROMPT" | bash "$PROVIDER_SCRIPT" 2>&1)
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  sia_err "Provider failed with exit code $rc."
  echo "$RESPONSE" >&2
  exit 3
fi

# Save response
RESPONSE_FILE="$OUTPUT_DIR/attempt-${ATTEMPT}.md"
if [[ "$ACTIVE_MODE" == "review" ]]; then
  RESPONSE_FILE="$OUTPUT_DIR/review.md"
elif [[ "$ACTIVE_MODE" == "architect" ]]; then
  # Architect writes directly to tasks dir
  RESPONSE_FILE="$TASK_FILE"
fi

echo "$RESPONSE" > "$RESPONSE_FILE"
sia_log "Model response saved to: $RESPONSE_FILE"

# If in review or architect mode, stop here
if [[ "$ACTIVE_MODE" == "review" ]]; then
  sia_log "Review completed successfully. Output written to review.md. Zero files modified."
  exit 0
fi

if [[ "$ACTIVE_MODE" == "architect" ]]; then
  sia_log "Architect mode completed. Task contract created/updated at: $TASK_FILE"
  exit 0
fi

# 3. Apply changes based on mode
sia_log "Applying changes..."

# Parse Scope files list
SCOPE_PATHS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && SCOPE_PATHS+=("$line")
done < <(sia_parse_section "scope" "$TASK_FILE")

if [[ "$ACTIVE_MODE" == "patch" ]]; then
  # Patch mode SEARCH/REPLACE applied via python helper
  set +e
  python3 "$SCRIPT_DIR/lib/sia_apply.py" "$RESPONSE_FILE" "${SCOPE_PATHS[@]}"
  apply_rc=$?
  set -e
  if [[ $apply_rc -ne 0 ]]; then
    sia_err "Applying patch blocks failed with exit code $apply_rc."
    exit $apply_rc
  fi
else
  # Default whole-file mode (legacy)
  is_in_scope() {
    local file="$1"
    for scope_path in "${SCOPE_PATHS[@]}"; do
      if [[ "$scope_path" == */ ]]; then
        [[ "$file" == "$scope_path"* ]] && return 0
      else
        [[ "$file" == "$scope_path" ]] && return 0
      fi
    done
    return 1
  }

  flush_file() {
    local file="$1" content="$2"
    [[ -z "$file" ]] && return
    if is_in_scope "$file"; then
      sia_log "Writing changes to: $file"
      mkdir -p "$(dirname "$PROJECT_ROOT/$file")"
      printf '%s' "$content" > "$PROJECT_ROOT/$file"
    else
      sia_err "VIOLATION: Blocked write attempt to file outside Scope: $file"
      exit 2
    fi
  }

  current_file=""
  current_content=""
  # Read line-by-line and flush whole-file blocks
  # Keep trailing empty lines
  while IFS= read -r line; do
    if [[ "$line" =~ ^===\ FILE:\ (.+)\ ===$ ]]; then
      flush_file "$current_file" "$current_content"
      current_file="${BASH_REMATCH[1]}"
      current_content=""
    elif [[ -n "$current_file" ]]; then
      current_content+="${line}"$'\n'
    fi
  done <<< "$RESPONSE"
  flush_file "$current_file" "$current_content"
fi

# 4. Verification Gate Trigger (if not orchestrated)
if [[ "${ORCHESTRATED:-}" != "--orchestrated" && "${SIA_ORCHESTRATED:-}" != "true" ]]; then
  sia_log "Running Gate verification..."
  bash "$SCRIPT_DIR/sia-gate.sh" "$TASK"
fi
