#!/usr/bin/env bash
# SIA Gate — Agnostic & Hardened Implementation
# Usage: ./scripts/sia-gate.sh TASK-XXX
# Exit codes:
#   0 — pass
#   1 — logic fail (retry allowed)
#   2 — violation (escalate immediately, no retry)
#   3 — infra fail (external dependency down)

set -euo pipefail

TASK="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source common helpers
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Inicjalizacja konfiguracji
sia_load_config

# Zweryfikuj czy jesteśmy w repozytorium Git
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  sia_err "SIA requires a valid Git repository to function safely! Run 'git init' first."
  exit 3
fi

# Get active provider settings for the worker role
sia_get_role_provider_env "worker"

TASK_FILE="$PROJECT_ROOT/${SIA_PATH_TASKS_DIR}/${TASK}.md"

if [[ -z "$TASK" ]]; then
  sia_err "TASK argument required (e.g. TASK-001)"
  exit 2
fi

if [[ ! -f "$TASK_FILE" ]]; then
  sia_err "Task file not found: $TASK_FILE"
  exit 2
fi

# ---------------------------------------------------------------------------
# 1. Parsowanie Scope z pliku zadania
# ---------------------------------------------------------------------------
SCOPE_PATHS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && SCOPE_PATHS+=("$line")
done < <(sia_parse_section "scope" "$TASK_FILE")

if [[ ${#SCOPE_PATHS[@]} -eq 0 ]]; then
  sia_err "No Scope paths found in task $TASK_FILE"
  exit 2
fi

sia_log "=== SIA Gate: $TASK ==="
sia_log "Scope: ${SCOPE_PATHS[*]}"

# Run formatting on Scope files if config specifies it
if [[ -n "${SIA_CMD_FORMAT:-}" ]]; then
  sia_log "Running formatter best-effort..."
  for sf in "${SCOPE_PATHS[@]}"; do
    full_sf="$PROJECT_ROOT/$sf"
    if [[ -f "$full_sf" ]]; then
      # Replace placeholder if it exists, or run command directly
      # We attempt to format the file
      FMT_CMD="${SIA_CMD_FORMAT//\{\}/$sf}"
      python3 "$SCRIPT_DIR/lib/run_cmd.py" \
        --timeout "$SIA_RUN_COMMAND_TIMEOUT_SEC" \
        --sandbox "none" \
        -- "$FMT_CMD" >/dev/null 2>&1 || true
    fi
  done
fi

# ---------------------------------------------------------------------------
# 2. Scope check
# ---------------------------------------------------------------------------
sia_log ""
sia_log "--- [1/5] Scope check ---"
cd "$PROJECT_ROOT"

# Get changed/untracked files
# Deduplicate using sort -u
CHANGED_FILES=$( (git diff --name-only HEAD --relative 2>/dev/null; git diff --name-only --cached --relative 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null) | sort -u )

violations=()
while IFS= read -r changed_file; do
  [[ -z "$changed_file" ]] && continue
  
  # Filter by exclude_dirs
  is_excluded=0
  for ex_dir in $SIA_EXCLUDE_DIRS; do
    if [[ "$changed_file" == "$ex_dir"* ]]; then
      is_excluded=1
      break
    fi
  done
  [[ $is_excluded -eq 1 ]] && continue

  # Verify if in scope
  if ! sia_in_scope "$changed_file" "${SCOPE_PATHS[@]}"; then
    violations+=("$changed_file")
  fi
done <<< "$CHANGED_FILES"

if [[ ${#violations[@]} -gt 0 ]]; then
  sia_err "VIOLATION: Modified files outside task Scope:"
  printf '  %s\n' "${violations[@]}" >&2
  exit 2
fi
sia_log "OK"

# ---------------------------------------------------------------------------
# 3. Brain guard
# ---------------------------------------------------------------------------
sia_log ""
sia_log "--- [2/5] Brain guard ---"
BRAIN_CHANGES=$(echo "$CHANGED_FILES" | grep "^${SIA_PATH_BRAIN_DIR}/" || true)
if [[ -n "$BRAIN_CHANGES" ]]; then
  sia_err "VIOLATION: Worker modified ${SIA_PATH_BRAIN_DIR}/ files! Workers are READ-ONLY."
  echo "$BRAIN_CHANGES" >&2
  exit 2
fi
sia_log "OK"

# ---------------------------------------------------------------------------
# 4. Forbidden patterns check
# ---------------------------------------------------------------------------
sia_log ""
sia_log "--- [3/5] Forbidden patterns ---"
DIFF_CONTENT=$(git diff HEAD --relative 2>/dev/null; git diff --cached --relative 2>/dev/null)
NEW_FILES=$(git ls-files --others --exclude-standard 2>/dev/null)
if [[ -n "$NEW_FILES" ]]; then
  while IFS= read -r nf; do
    [[ -z "$nf" ]] && continue
    # Skip excluded directories
    is_excluded=0
    for ex_dir in $SIA_EXCLUDE_DIRS; do
      if [[ "$nf" == "$ex_dir"* ]]; then is_excluded=1; break; fi
    done
    [[ $is_excluded -eq 1 ]] && continue
    
    if [[ -f "$nf" ]]; then
      # Append new file diff content separated by newline
      DIFF_CONTENT+=$'\n'
      DIFF_CONTENT+=$(sed 's/^/+/' "$nf")
    fi
  done <<< "$NEW_FILES"
fi

found_forbidden=0
for pattern in $SIA_FORBIDDEN_PATTERNS; do
  # Match prefix '+' for added lines containing forbidden pattern
  if echo "$DIFF_CONTENT" | grep -qE "^\+.*${pattern}"; then
    sia_err "VIOLATION: Forbidden pattern found in diff: $pattern"
    found_forbidden=1
  fi
done

if [[ $found_forbidden -eq 1 ]]; then
  exit 2
fi
sia_log "OK"

# ---------------------------------------------------------------------------
# 5. Assertion-diff check
# ---------------------------------------------------------------------------
sia_log ""
sia_log "--- [4/5] Assertion-diff check ---"
REMOVED_ASSERTIONS=$(git diff HEAD --relative 2>/dev/null | grep -E "^-.*\b(expect|toBe|toEqual|assert|toHaveBeenCalled)\b" || true)
if [[ -n "$REMOVED_ASSERTIONS" ]]; then
  sia_err "VIOLATION: Existing test assertions were removed or modified:"
  echo "$REMOVED_ASSERTIONS" >&2
  exit 2
fi
sia_log "OK"

# ---------------------------------------------------------------------------
# 6. Tests + lint
# ---------------------------------------------------------------------------
sia_log ""
sia_log "--- [5/5] Tests & lint ---"

run_gate_cmd() {
  local cmd="$1"
  python3 "$SCRIPT_DIR/lib/run_cmd.py" \
    --timeout "$SIA_RUN_COMMAND_TIMEOUT_SEC" \
    --sandbox "$SIA_SANDBOX_MODE" \
    --docker-image "$SIA_SANDBOX_DOCKER_IMAGE" \
    -- "$cmd"
}

if [[ -n "${SIA_CMD_TEST:-}" ]]; then
  sia_log "Running tests: $SIA_CMD_TEST..."
  set +e
  run_gate_cmd "$SIA_CMD_TEST" 2>&1
  rc=$?
  set -e
  if [[ $rc -eq 124 ]]; then
    sia_err "FAIL: Unit tests timed out!"
    exit 1
  elif [[ $rc -ne 0 ]]; then
    sia_err "FAIL: Unit tests failed (exit code $rc)"
    exit 1
  fi
fi

if [[ -n "${SIA_CMD_LINT:-}" ]]; then
  # Lint only on changed files
  CHANGED_TS=$(git diff --name-only HEAD --relative 2>/dev/null | grep -E '\.(ts|tsx|js|jsx|py|go|rs|sh)$' || true)
  if [[ -n "$CHANGED_TS" ]]; then
    # Filter out excluded dirs
    FILTERED_TS=""
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      is_ex=0
      for ex in $SIA_EXCLUDE_DIRS; do
        if [[ "$f" == "$ex"* ]]; then is_ex=1; break; fi
      done
      if [[ $is_ex -eq 0 ]]; then
        FILTERED_TS+="$f "
      fi
    done <<< "$CHANGED_TS"

    if [[ -n "$FILTERED_TS" ]]; then
      sia_log "Running linter: $SIA_CMD_LINT on files: $FILTERED_TS..."
      set +e
      run_gate_cmd "$SIA_CMD_LINT $FILTERED_TS" 2>&1
      rc=$?
      set -e
      if [[ $rc -eq 124 ]]; then
        sia_err "FAIL: Linter timed out!"
        exit 1
      elif [[ $rc -ne 0 ]]; then
        sia_err "FAIL: Linter failed (exit code $rc)"
        exit 1
      fi
    fi
  fi
fi

sia_log ""
sia_log "=== GATE PASS: $TASK ==="
exit 0
