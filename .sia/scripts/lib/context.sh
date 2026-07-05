#!/usr/bin/env bash
# SIA Context Wrapper

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Builds prompt using python3 context_builder.py
# Outputs prompt to stdout
sia_build_prompt() {
  local task_file="$1"
  local attempt_num="$2"
  local max_attempts="$3"
  local feedback_file="$4"
  
  python3 "$LIB_DIR/context_builder.py" \
    "$PROJECT_ROOT" \
    "$task_file" \
    "$attempt_num" \
    "$max_attempts" \
    "$feedback_file"
}
