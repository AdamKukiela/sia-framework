#!/usr/bin/env bash
# SIA Integration & E2E Test Suite
# Runs in a clean temporary directory using git fixture and mock provider

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Setup temporary test directory
TEST_DIR=$(mktemp -d -t sia-test-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

echo "=== Setting up test workspace in $TEST_DIR ==="
cd "$TEST_DIR"
git init -b main
git config user.name "Test User"
git config user.email "test@example.com"

# Create directories
mkdir -p .brain/tasks .brain/wiki .worker/runs .worker/escalations .sia/scripts/lib/providers templates src tests

# Copy framework files (scripts & lib)
cp -r "$FRAMEWORK_DIR/.sia/scripts/"* "./.sia/scripts/"
chmod +x ./.sia/scripts/sia-gate.sh ./.sia/scripts/sia-worker.sh ./.sia/scripts/sia-run.sh
chmod +x ./.sia/scripts/lib/run_cmd.py ./.sia/scripts/lib/sia_apply.py

# Create a dummy config (sia.json) using mock provider
cat <<EOF > sia.json
{
  "version": 2,
  "providers": {
    "mock-prov": {
      "provider": "mock",
      "model": "mock-model"
    }
  },
  "roles": {
    "worker": "mock-prov"
  },
  "run": {
    "max_attempts": 3,
    "total_timeout_sec": 60,
    "command_timeout_sec": 5,
    "feedback_head_lines": 5,
    "feedback_tail_lines": 5,
    "default_mode": "worker"
  },
  "sandbox": {
    "mode": "none"
  },
  "context": {
    "repo_map": false,
    "budget_pct": 80
  },
  "commands": {
    "test": "bash src/math.test.sh",
    "lint": "bash -n src/math.sh"
  },
  "forbidden_patterns": ["@ts-ignore", "eslint-disable"],
  "exclude_dirs": ["node_modules", ".worker", ".brain"]
}
EOF

# Create dummy source files
cat <<EOF > src/math.sh
add() {
  echo \$((\$1 + \$2))
}
EOF

cat <<EOF > src/math.test.sh
source src/math.sh
res=\$(add 2 3)
if [[ \$res -eq 5 ]]; then
  exit 0
else
  echo "Expected 5, got \$res" >&2
  exit 1
fi
EOF

# Create first TASK contract
cat <<EOF > .brain/tasks/TASK-001.md
# TASK-001: Fix add function
## Scope
- src/math.sh
EOF

# Commit initial version
git add .
git commit -m "initial commit"

echo "=== SETUP COMPLETE ==="
echo ""

# ---------------------------------------------------------------------------
# Test 1: Gate out-of-scope check (should exit 2)
# ---------------------------------------------------------------------------
echo "--- TEST 1: Out-of-scope modification check ---"
echo "hack" >> src/math.test.sh # math.test.sh is not in TASK-001 Scope
set +e
./.sia/scripts/sia-gate.sh TASK-001
rc=$?
set -e
if [[ $rc -ne 2 ]]; then
  echo "TEST 1 FAILED: Expected exit code 2, got $rc" >&2
  exit 1
fi
echo "TEST 1 PASSED: Out-of-scope caught successfully!"
git checkout -- src/math.test.sh
echo ""

# ---------------------------------------------------------------------------
# Test 2: Gate .brain/ guard check (should exit 2)
# ---------------------------------------------------------------------------
echo "--- TEST 2: .brain/ modification guard check ---"
echo "modification" >> .brain/tasks/TASK-001.md
set +e
./.sia/scripts/sia-gate.sh TASK-001
rc=$?
set -e
if [[ $rc -ne 2 ]]; then
  echo "TEST 2 FAILED: Expected exit code 2, got $rc" >&2
  exit 1
fi
echo "TEST 2 PASSED: .brain modification guard triggered!"
git checkout -- .brain/tasks/TASK-001.md
echo ""

# ---------------------------------------------------------------------------
# Test 3: Gate test failure check (should exit 1)
# ---------------------------------------------------------------------------
echo "--- TEST 3: Test failure check ---"
cat <<EOF > src/math.sh
add() {
  echo 999 # incorrect output
}
EOF
set +e
./.sia/scripts/sia-gate.sh TASK-001
rc=$?
set -e
if [[ $rc -ne 1 ]]; then
  echo "TEST 3 FAILED: Expected exit code 1, got $rc" >&2
  exit 1
fi
echo "TEST 3 PASSED: Test logic failure detected!"
git checkout -- src/math.sh
echo ""

# ---------------------------------------------------------------------------
# Test 4: E2E Attempt Retry Loop (Attempt 1 fails, Attempt 2 succeeds)
# ---------------------------------------------------------------------------
echo "--- TEST 4: E2E Orchestrator Retry Loop check ---"
export SIA_MOCK_DIR="/tmp/sia-mocks-$$"
mkdir -p "$SIA_MOCK_DIR"
trap 'rm -rf "$TEST_DIR" "$SIA_MOCK_DIR"' EXIT

# Attempt 1: Output broken code (returns incorrect add function)
cat <<EOF > "$SIA_MOCK_DIR/response-1.txt"
=== FILE: src/math.sh ===
add() {
  echo 999
}
EOF

# Attempt 2: Output correct code
cat <<EOF > "$SIA_MOCK_DIR/response-2.txt"
=== FILE: src/math.sh ===
add() {
  echo \$((\$1 + \$2))
}
EOF

# Run sia-run.sh
set +e
./.sia/scripts/sia-run.sh TASK-001
run_rc=$?
set -e

if [[ $run_rc -ne 0 ]]; then
  echo "TEST 4 FAILED: Expected sia-run.sh exit 0, got $run_rc" >&2
  exit 1
fi

# Verify the file actually contains the correct code from attempt 2
if ! grep -q "add 2 3" src/math.test.sh || ! grep -q "\$1 + \$2" src/math.sh; then
  echo "TEST 4 FAILED: Final code does not match attempt 2" >&2
  exit 1
fi
echo "TEST 4 PASSED: Retry loop resolved successfully on Attempt 2!"
git checkout -- src/math.sh
rm -rf .worker/runs/TASK-001
echo ""

# ---------------------------------------------------------------------------
# Test 5: Patch Mode (SEARCH/REPLACE format application)
# ---------------------------------------------------------------------------
echo "--- TEST 5: Patch Mode (SEARCH/REPLACE) check ---"
# Edit config to set default_mode to patch
python3 -c '
import json
with open("sia.json", "r") as f:
    cfg = json.load(f)
cfg["run"]["default_mode"] = "patch"
with open("sia.json", "w") as f:
    json.dump(cfg, f)
'

# Set math.sh initial state
cat <<EOF > src/math.sh
add() {
  # legacy comments
  echo \$((\$1 + \$2))
}
EOF
git add src/math.sh && git commit -m "set math.sh state"

# Mock SEARCH/REPLACE response
cat <<EOF > "$SIA_MOCK_DIR/response-1.txt"
=== FILE: src/math.sh ===
<<<<<<< SEARCH
  # legacy comments
  echo \$((\$1 + \$2))
=======
  # updated comments
  echo \$((\$1 + \$2)) # fast path
>>>>>>> REPLACE
EOF

# Run worker
./.sia/scripts/sia-worker.sh TASK-001 1 --orchestrated

# Verify math.sh contains patch
if ! grep -q "fast path" src/math.sh; then
  echo "TEST 5 FAILED: Patch not applied to src/math.sh" >&2
  exit 1
fi
echo "TEST 5 PASSED: Patch applied correctly!"
echo ""

echo "=== ALL TESTS PASSED SUCCESSFULLY ==="
exit 0
