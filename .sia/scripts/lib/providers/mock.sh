#!/usr/bin/env bash
# SIA Mock Provider (For Tests)

# Variables:
#   SIA_MOCK_DIR (e.g. tests/fixtures/mocks)
#   SIA_ATTEMPT (attempt number)

MOCK_DIR="${SIA_MOCK_DIR:-/tmp/sia-mocks}"
ATTEMPT="${SIA_ATTEMPT:-1}"

MOCK_FILE="${MOCK_DIR}/response-${ATTEMPT}.txt"
FALLBACK_FILE="${MOCK_DIR}/response-1.txt"

if [[ -f "$MOCK_FILE" ]]; then
  cat "$MOCK_FILE"
elif [[ -f "$FALLBACK_FILE" ]]; then
  cat "$FALLBACK_FILE"
else
  echo "ERROR: Mock response file not found at: $MOCK_FILE or $FALLBACK_FILE" >&2
  exit 3
fi
