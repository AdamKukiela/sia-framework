#!/usr/bin/env bash
# SIA Orchestrator — Loop, Retry, Timeout, and Mode handling
# Usage: ./scripts/sia-run.sh TASK-XXX [--mode worker|patch|review|architect] [--max-attempts N]

set -euo pipefail

TASK="${1:-}"
shift || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source common library
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Inicjalizacja konfiguracji
sia_load_config

if [[ -z "$TASK" ]]; then
  echo "Usage: ./scripts/sia-run.sh TASK-XXX [--mode worker|patch|review|architect] [--max-attempts N]" >&2
  exit 2
fi

# Parsowanie argumentów CLI
CLI_MODE=""
CLI_MAX_ATTEMPTS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      CLI_MODE="$2"
      shift 2
      ;;
    --max-attempts)
      CLI_MAX_ATTEMPTS="$2"
      shift 2
      ;;
    *)
      echo "Unknown CLI argument: $1" >&2
      exit 2
      ;;
  esac
done

# Resolve effective parameters
export SIA_RUN_MODE="${CLI_MODE:-$SIA_RUN_DEFAULT_MODE}"
MAX_ATTEMPTS="${CLI_MAX_ATTEMPTS:-$SIA_RUN_MAX_ATTEMPTS}"

# Verify task file existence early (fail fast)
TASK_FILE="$PROJECT_ROOT/${SIA_PATH_TASKS_DIR}/${TASK}.md"
if [[ "$SIA_RUN_MODE" != "architect" && ! -f "$TASK_FILE" ]]; then
  sia_err "Task file not found at: $TASK_FILE"
  sia_err "To create it, copy the template: cp .sia/templates/TASK_TEMPLATE.md $TASK_FILE"
  exit 1
fi

# Check for review/architect modes (they don't run retry loops or gates)
if [[ "$SIA_RUN_MODE" == "review" || "$SIA_RUN_MODE" == "architect" ]]; then
  sia_log "Running role-based utility command in mode '$SIA_RUN_MODE'..."
  export SIA_ORCHESTRATED="true"
  bash "$SCRIPT_DIR/sia-worker.sh" "$TASK" "1"
  exit 0
fi

# Reset / Initialize runs folder
OUTPUT_DIR="$PROJECT_ROOT/${SIA_PATH_RUNS_DIR}/${TASK}"
mkdir -p "$OUTPUT_DIR"
FEEDBACK_FILE="$OUTPUT_DIR/feedback.txt"
rm -f "$FEEDBACK_FILE"

# Helper for truncating tool output for LLM consumption
truncate_feedback() {
  local input_file="$1"
  python3 -c '
import sys
head_limit = int(sys.argv[1])
tail_limit = int(sys.argv[2])
lines = sys.stdin.readlines()

if len(lines) <= (head_limit + tail_limit):
    sys.stdout.writelines(lines)
else:
    sys.stdout.writelines(lines[:head_limit])
    sys.stdout.write(f"\n... [{len(lines) - head_limit - tail_limit} lines omitted from console output] ...\n\n")
    sys.stdout.writelines(lines[-tail_limit:])
' "$SIA_RUN_FEEDBACK_HEAD_LINES" "$SIA_RUN_FEEDBACK_TAIL_LINES" < "$input_file"
}

# Start orchestrator
sia_log "Starting SIA Orchestrator for $TASK"
sia_log "Mode: $SIA_RUN_MODE, Max Attempts: $MAX_ATTEMPTS, Timeout: ${SIA_RUN_TOTAL_TIMEOUT_SEC}s"

START_TIME=$(date +%s)
export SIA_ORCHESTRATED="true"

ATTEMPT=1
while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
  # Check wall-clock timeout
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  if [[ $ELAPSED -ge $SIA_RUN_TOTAL_TIMEOUT_SEC ]]; then
    reason="RUN TIMEOUT: Total execution time ($ELAPSED seconds) exceeded wall-clock limit ($SIA_RUN_TOTAL_TIMEOUT_SEC seconds)."
    sia_err "$reason"
    sia_write_escalation "$TASK" "124" "$reason"
    exit 1
  fi

  sia_log ""
  sia_log "====================================================================="
  sia_log "=== Attempt $ATTEMPT of $MAX_ATTEMPTS ==="
  sia_log "====================================================================="
  
  # 1. Run worker step
  # Redirect worker output to a temporary log file to capture errors
  WORKER_LOG="$OUTPUT_DIR/attempt-${ATTEMPT}-worker-log.txt"
  set +e
  bash "$SCRIPT_DIR/sia-worker.sh" "$TASK" "$ATTEMPT" 2>&1 | tee "$WORKER_LOG"
  worker_rc=$?
  set -e

  if [[ $worker_rc -eq 3 ]]; then
    sia_err "Infrastructure failure during attempt $ATTEMPT. Skipping retry count increment."
    rm -f "$WORKER_LOG"
    exit 3
  elif [[ $worker_rc -eq 2 ]]; then
    reason=$(cat "$WORKER_LOG")
    sia_err "VIOLATION during attempt $ATTEMPT: $reason"
    sia_write_escalation "$TASK" "2" "$reason"
    rm -f "$WORKER_LOG"
    exit 2
  elif [[ $worker_rc -ne 0 ]]; then
    # Parse apply/validation failure (exit code 1)
    sia_err "Code patch application failed on attempt $ATTEMPT."
    echo "--- PATCH/APPLY FAIL LOG ---" >> "$FEEDBACK_FILE"
    truncate_feedback "$WORKER_LOG" >> "$FEEDBACK_FILE"
    rm -f "$WORKER_LOG"
    ATTEMPT=$((ATTEMPT + 1))
    continue
  fi
  
  # Worker executed and applied changes successfully (exited 0)
  rm -f "$WORKER_LOG"

  # 2. Run verification gate
  GATE_LOG="$OUTPUT_DIR/attempt-${ATTEMPT}-gate-log.txt"
  sia_log "Running verification gate..."
  set +e
  bash "$SCRIPT_DIR/sia-gate.sh" "$TASK" 2>&1 | tee "$GATE_LOG"
  gate_rc=$?
  set -e

  if [[ $gate_rc -eq 0 ]]; then
    sia_log "GATE PASS! Task $TASK completed successfully on attempt $ATTEMPT."
    # Clean temporary log
    rm -f "$GATE_LOG"
    exit 0
  elif [[ $gate_rc -eq 2 ]]; then
    # Security/Scope Violation
    reason=$(cat "$GATE_LOG")
    sia_err "VIOLATION detected by Gate: $reason"
    sia_write_escalation "$TASK" "2" "$reason"
    rm -f "$GATE_LOG"
    exit 2
  elif [[ $gate_rc -eq 3 ]]; then
    # Infrastructure error
    sia_err "Infrastructure failure detected by Gate. Exiting."
    rm -f "$GATE_LOG"
    exit 3
  else
    # Logic or test/lint failure (exit code 1)
    sia_err "Verification failed on attempt $ATTEMPT."
    echo "--- GATE VERIFICATION FAILURE LOG ---" > "$FEEDBACK_FILE"
    truncate_feedback "$GATE_LOG" >> "$FEEDBACK_FILE"
    rm -f "$GATE_LOG"
  fi

  ATTEMPT=$((ATTEMPT + 1))
done

# Loop finished without passing the gate
reason="Max attempts ($MAX_ATTEMPTS) reached without passing the gate verification."
sia_err "$reason"
sia_write_escalation "$TASK" "1" "$reason"
exit 1
