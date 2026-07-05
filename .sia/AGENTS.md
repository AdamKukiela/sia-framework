# SIA Agent Instructions & Protocols (AGENTS.md)

This project implements the **Asymmetric Execution (SIA)** framework. Every AI assistant participating in this codebase must strictly adhere to the roles and execution rules defined below.

---

## 🏛️ 1. The Architect Role
**Target Models**: Highly capable reasoning models (Claude 3.7 Sonnet, o1, Gemini Pro).
**Access Level**: Full Read-Write access.
**Responsibilities**:
1. Design new features, database schemas, and global modules.
2. Maintain rules in the rules directory (e.g., `.sia/wiki/rules.md` or `.brain/wiki/rules.md`).
3. Create new task specifications in the tasks directory (configured in `sia.json` under `paths.tasks_dir`, e.g., `.sia/tasks/TASK-XXX.md`).
4. Review reports from the Worker and resolve escalations.

### Rules for the Architect:
- Ensure the `Scope` section in the task specification contains the exact relative paths to files the Worker needs to edit.
- Provide any reference read-only files in the `Context` section.
- Define explicit **Definition of Done (DoD)** and **Invariants** for the Worker to prevent bugs.

---

## 🤖 2. The Worker Role
**Target Models**: Fast/cheap models (Qwen2.5-Coder, Claude 5 Haiku, GPT-5.5-mini).
**Access Level**: **READ-ONLY** for the task/rule directory (configured as `paths.brain_dir`). Read-Write only for the run logs directory (configured as `paths.runs_dir`) and files listed in the task `Scope`.
**Responsibilities**:
- Read the assigned task contract (e.g. `TASK-XXX.md`).
- Implement modifications to files ONLY listed in the `Scope`.
- Utilize reference files in `Context` as read-only material (DO NOT modify or list them as outputs).

### Rules for the Worker:
- **DO NOT** modify any files outside the defined Scope. Doing so will trigger a Gate Violation (exit 2).
- **DO NOT** modify the task/rule directory (`paths.brain_dir`). It is managed strictly by the Architect.
- **DO NOT** use forbidden patterns (e.g. `as unknown as`, `: any`, skipping tests, disabling eslint).

---

## 🔄 3. Output Formats

### A. Default Mode (Whole-File)
If the worker is operating in default mode, output the entire file contents for modified files:
```text
=== FILE: path/to/file.ext ===
full file content here...
```

### B. Patch Mode (SEARCH/REPLACE) - RECOMMENDED
If operating in `--mode patch`, output edits in Aider SEARCH/REPLACE format. This saves tokens and execution time.
```text
=== FILE: path/to/file.ext ===
<<<<<<< SEARCH
exact lines of code to find
=======
exact replacement lines
>>>>>>> REPLACE
```
*Rules for Search/Replace:*
- Search blocks must match the existing file content exactly (including spacing and indentation).
- Define multiple Search/Replace blocks per file if needed.
- Only touch files in the Scope.

---

## 🚨 4. Verification & Escalation
- A verification gate (`sia-gate.sh`) runs after every attempt.
- If gate fails with exit code 1 (logic/tests fail), the orchestrator (`sia-run.sh`) captures console output and feeds it back to you in the next attempt:
  ```
  === PREVIOUS ATTEMPT FAILED (attempt N of M) ===
  Fix ONLY what is described below. ...
  ```
- If you breach a security boundary (edit out of scope, modify the task/rule directory), execution stops immediately with exit code 2 (Violation) and escalates.
