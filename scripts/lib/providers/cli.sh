#!/usr/bin/env bash
# SIA CLI / Local Agents Provider

# Variables inherited:
#   SIA_ACTIVE_MODEL
#   SIA_ACTIVE_CMD

PROMPT=$(cat)

# 1. Custom Command Override (Generic CLI)
if [[ -n "${SIA_ACTIVE_CMD:-}" ]]; then
  echo "$PROMPT" | eval "$SIA_ACTIVE_CMD"
  exit $?
fi

# 2. Hardcoded Fallbacks
if [[ "$SIA_ACTIVE_MODEL" == "claude" ]]; then
  if ! command -v claude >/dev/null 2>&1; then
    echo "ERROR: 'claude' CLI command not found!" >&2
    exit 3
  fi
  # Invoke Claude CLI in non-interactive / text output format
  echo "$PROMPT" | claude -p --output-format text 2>/dev/null
elif [[ "$SIA_ACTIVE_MODEL" == "gemini" || "$SIA_ACTIVE_MODEL" == "agy" ]]; then
  if command -v agy >/dev/null 2>&1; then
    echo "$PROMPT" | agy 2>/dev/null
  elif command -v gemini >/dev/null 2>&1; then
    echo "$PROMPT" | gemini 2>/dev/null
  else
    echo "ERROR: Neither 'agy' nor 'gemini' CLI command was found!" >&2
    exit 3
  fi
elif [[ "$SIA_ACTIVE_MODEL" == "codex" ]]; then
  if ! command -v codex >/dev/null 2>&1; then
    echo "ERROR: 'codex' CLI command not found!" >&2
    exit 3
  fi
  # Codex warning about writing files. We run it in read-only sandbox mode.
  echo "WARNING: Running Codex agent. Restricting to read-only sandbox mode." >&2
  echo "$PROMPT" | codex exec --sandbox read-only --skip-git-repo-check 2>/dev/null
else
  echo "ERROR: Unsupported CLI model: $SIA_ACTIVE_MODEL" >&2
  exit 3
fi
