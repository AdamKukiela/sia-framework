# SIA — Asymmetric Execution Framework (README.md)

SIA is a lightweight, language-agnostic framework for safely delegating code generation to AI models. It separates tasks into two roles: a high-level **Architect** (who designs tasks) and a restricted **Worker** (who executes them). 

By isolating worker models, defining strict file-scopes, and running automated gating checks inside optional sandboxes, SIA prevents AI models from introducing breaking changes or violating architectural boundaries.

---

## 🚀 Key Features (v2.0)
* **Automated Retry Loop with Test Feedback**: Captured terminal error stacks are fed back into subsequent model prompts to enable auto-correction (similar to Aider/SWE-agent).
* **Patch Mode (SEARCH/REPLACE)**: Emits small, precise block diffs instead of writing whole files. Saves up to 80% token volume.
* **Role-Based Provider Matrix**: Assign different models to different tasks (e.g., local Qwen2.5-Coder for boilerplate, Claude-3.7-Sonnet for design & review).
* **Sandboxed Verification Gate**: Execute testing and linting scripts with strict timeouts inside Docker containers or native macOS sandboxes.
* **Token Budget & Context Truncation**: Intelligently compiles prompt sizes, truncating reference documents while preserving scope targets.

---

## 📦 Default Project Layout
```text
.sia/
  tasks/           # TASK-XXX.md contract specifications (Written by Architect)
  wiki/            # rules.md, design decisions, patterns (Architect write-only)
  AGENTS.md        # System instructions for AI agents
  scripts/
    sia-run.sh     # Orchestrator CLI (retry loop, timeout checks, mode routing)
    sia-worker.sh  # Stateless worker (prompt compiler, provider dispatch, block apply)
    sia-gate.sh    # Hardened verification gate (scope check, forbidden rules, tests)
.sia-worker/
  runs/            # Execution attempts logs, feedback buffers
  escalations/     # Critical failure and violation reports
```
*(Note: Folder paths are fully customizable in `sia.json`)*

---

## 🚀 Quick Start & Installation

### 1. Install & Configure (Interactive Wizard)
Run the following command in your project root. The installer will download the scripts and guide you through an interactive setup to customize folder names, choose your AI provider, and configure test commands:
```bash
curl -fsSL https://raw.githubusercontent.com/AdamKukiela/sia-framework/main/install.sh | bash
```

### 2. Configure `sia.json`
Configure providers, testing commands, and rules in `sia.json` in your project root:
```json
{
  "version": 2,
  "providers": {
    "local": {
      "provider": "ollama",
      "model": "qwen2.5-coder:14b",
      "base_url": "http://localhost:11434"
    },
    "claude-api": {
      "provider": "anthropic",
      "model": "claude-5-sonnet",
      "api_key_env": "ANTHROPIC_API_KEY"
    }
  },
  "roles": {
    "worker": "local",
    "architect": "claude-api",
    "review": "claude-api"
  },
  "commands": {
    "test": "npm run test:unit",
    "lint": "npx eslint --format compact"
  }
}
```

If using Ollama, pull the default local model:
```bash
ollama pull qwen2.5-coder:14b
```

### 💡 API-Keyless Setup (Subscriptions via CLI)
If you don't have direct LLM API keys but pay for local subscriptions (e.g., Claude Code, Antigravity, or Codex), you can configure the `"cli"` provider. This pipes prompts directly to your authenticated local CLI tools:

* **Predefined Tools**: Set `"model"` to `"claude"` (uses `claude` CLI) or `"agy"` / `"gemini"` (uses `agy` CLI).
* **Generic / Custom CLI**: Define a `"cmd"` parameter to pipe prompt data to any custom tool.

```json
  "providers": {
    "claude-cli-sub": {
      "provider": "cli",
      "model": "claude"
    },
    "agy-cli-sub": {
      "provider": "cli",
      "model": "agy"
    },
    "custom-cli-tool": {
      "provider": "cli",
      "cmd": "codex exec --sandbox read-only"
    }
  }
```

### 3. Workflow Modes

Run the orchestrator with `./.sia/scripts/sia-run.sh TASK-XXX [flags]`:

#### A. Coder (Worker) Mode
Implement changes using whole-file output blocks:
```bash
./.sia/scripts/sia-run.sh TASK-001 --mode worker
```

#### B. Patch Mode (Default / Recommended)
Implement changes using SEARCH/REPLACE blocks. Faster and token-efficient:
```bash
./.sia/scripts/sia-run.sh TASK-001 --mode patch
```

#### C. Review Mode
Read-only review of current code changes against the task description. Outputs a report to the configured runs directory (e.g. `.sia-worker/runs/TASK-XXX/review.md`) without modifying files or running gates:
```bash
./.sia/scripts/sia-run.sh TASK-001 --mode review
```

#### D. Architect Mode
Generates a new task specification file in your configured tasks directory (e.g. `.sia/tasks/TASK-XXX.md` or `.brain/tasks/TASK-XXX.md`) using the advanced architect model:
```bash
./.sia/scripts/sia-run.sh TASK-042 --mode architect
```

---

## 🛡️ Sandbox & Hardening
Modify `sandbox.mode` in `sia.json`:
* `"none"`: Executes commands locally.
* `"docker"`: Executes test/lint commands inside the specified `docker_image` with network disabled (`--network none`) and volume mounts mapped to the current user.
* `"sandbox-exec"`: Restricts write operations using native macOS security profiles (`.sia/templates/sia.sb`).

---

## 🧪 Running Self-Tests
Verify your SIA framework installation by running the end-to-end integration test suite:
```bash
./.sia/tests/run_tests.sh
```

---

## 🛡️ Gating Exit Codes
- `0` — **PASS**: Code is verified and matches DoD.
- `1` — **Logic Fail**: Tests or linters failed. Worker will retry.
- `2` — **VIOLATION**: Worker modified files out of scope, modified `.brain/`, or skipped invariants. Loop stops and escalates immediately.
- `3` — **Infra Fail**: Environment error (e.g., API key missing, Ollama down).

---

## 📄 License
MIT
