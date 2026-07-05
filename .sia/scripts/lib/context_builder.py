#!/usr/bin/env python3
import sys
import os
import re

def get_repo_map(project_root, exclude_dirs, max_files):
    """
    Builds a tree structure or flat file list of the repository using git ls-files.
    """
    try:
        # Run git ls-files
        import subprocess
        res = subprocess.run(
            ["git", "ls-files"],
            cwd=project_root,
            capture_output=True,
            text=True,
            check=True
        )
        all_files = res.stdout.splitlines()
    except Exception:
        # Fallback to os.walk
        all_files = []
        for root, dirs, files in os.walk(project_root):
            # Apply exclude dirs
            dirs[:] = [d for d in dirs if d not in exclude_dirs]
            for file in files:
                rel_path = os.path.relpath(os.path.join(root, file), project_root)
                all_files.append(rel_path)

    # Filter by exclude dirs
    filtered_files = []
    for f in all_files:
        excluded = False
        for ex in exclude_dirs:
            if f.startswith(ex + "/") or f == ex:
                excluded = True
                break
        if not excluded:
            filtered_files.append(f)

    if len(filtered_files) > max_files:
        return f"[WARNING: Repository has too many files ({len(filtered_files)} > {max_files}). Skipping repo map to save token budget.]"

    # Format as a simple folder structure tree
    tree_lines = ["=== REPOSITORY FILE LIST ==="]
    for f in sorted(filtered_files):
        tree_lines.append(f"  {f}")
    return "\n".join(tree_lines)

def truncate_text(text, budget_chars):
    """
    Truncates reference text: keeps first 60% and last 20%
    """
    if len(text) <= budget_chars:
        return text, False
        
    keep_head = int(budget_chars * 0.6)
    keep_tail = int(budget_chars * 0.2)
    
    head_text = text[:keep_head]
    tail_text = text[-keep_tail:]
    
    truncated_msg = f"\n[... SIA CONTEXT TRUNCATED FOR TOKEN BUDGET ...]\n"
    return head_text + truncated_msg + tail_text, True

def build_prompt(
    project_root,
    task_file,
    attempt_num,
    max_attempts,
    feedback_text,
    active_mode,
    num_ctx,
    budget_pct,
    include_repo_map,
    repo_map_max_files,
    exclude_dirs
):
    # Parse sections from task file
    scope_files = []
    context_files = []
    
    with open(task_file, "r") as f:
        task_content = f.read()

    # Parse Scope & Context sections using regex
    scope_match = re.search(r"##\s*Scope(.*?)(##|$)", task_content, re.DOTALL | re.IGNORECASE)
    if scope_match:
        for line in scope_match.group(1).splitlines():
            line_clean = line.strip().split("<!--")[0].strip()
            if line_clean.startswith("-"):
                scope_files.append(line_clean[1:].strip())
                
    context_match = re.search(r"##\s*Context(.*?)(##|$)", task_content, re.DOTALL | re.IGNORECASE)
    if context_match:
        for line in context_match.group(1).splitlines():
            line_clean = line.strip().split("<!--")[0].strip()
            if line_clean.startswith("-"):
                context_files.append(line_clean[1:].strip())

    # Build Prompt Base
    system_instruction = f"You are a Worker in the SIA system. Implement EXACTLY what the TASK specifies."
    
    if active_mode == "patch":
        output_format = (
            "OUTPUT FORMAT (strict):\n"
            "- Output ONLY file blocks containing SEARCH/REPLACE blocks, no explanations, no markdown prose.\n"
            "- Use the EXACT same filenames as in CURRENT FILE headers.\n"
            "- Use the following format for each file block:\n"
            "=== FILE: path/to/file.ext ===\n"
            "<<<<<<< SEARCH\n"
            "stary kod do zastapienia\n"
            "=======\n"
            "nowy kod wstawiany\n"
            ">>>>>>> REPLACE\n"
            "- You can specify multiple SEARCH/REPLACE blocks for a single file.\n"
            "- Specify edits ONLY to files listed in the Scope."
        )
    elif active_mode == "review":
        output_format = (
            "OUTPUT FORMAT (strict):\n"
            "- Output a markdown review report explaining any bugs, syntax issues, or safety violations.\n"
            "- Do not write or apply code changes directly."
        )
    else:
        # Default worker (whole-file) mode
        output_format = (
            "OUTPUT FORMAT (strict):\n"
            "- Output ONLY file blocks, no explanations, no markdown prose.\n"
            "- Each file block must start with exactly '=== FILE: path/to/file.ext ===' then the full file content.\n"
            "- Use the EXACT same filenames as in CURRENT FILE headers.\n"
            "- Only output files that need changes."
        )

    # Compile feedback
    feedback_section = ""
    if feedback_text and attempt_num > 1:
        feedback_section = (
            f"\n\n=== PREVIOUS ATTEMPT FAILED (attempt {attempt_num-1} of {max_attempts}) ===\n"
            f"Fix ONLY what is described below. Do not repeat errors.\n"
            f"{feedback_text}\n"
        )

    # Read Scope Files (cannot be truncated)
    scope_section_lines = []
    for sf in scope_files:
        full_path = os.path.join(project_root, sf)
        if os.path.exists(full_path):
            with open(full_path, "r") as f:
                content = f.read()
            scope_section_lines.append(f"\n=== CURRENT FILE: {sf} ===\n{content}")
        else:
            # File doesn't exist yet, empty placeholder
            scope_section_lines.append(f"\n=== CURRENT FILE: {sf} ===\n[New file - currently empty]")
    scope_section = "".join(scope_section_lines)

    # Read Reference Files (can be truncated)
    context_section_dict = {}
    for cf in context_files:
        full_path = os.path.join(project_root, cf)
        if os.path.exists(full_path):
            with open(full_path, "r") as f:
                content = f.read()
            context_section_dict[cf] = content
        else:
            context_section_dict[cf] = "[Reference file not found on disk]"

    # Build Repository Map
    repo_map = ""
    if include_repo_map:
        repo_map = get_repo_map(project_root, exclude_dirs, repo_map_max_files)

    # Budget check
    # 1 token approx 3.5 characters. Budget in characters:
    total_budget_chars = int(num_ctx * 3.5 * (budget_pct / 100.0))
    
    # Calculate static sizes
    static_content = (
        system_instruction + "\n\n" +
        output_format + "\n\n" +
        "TASK:\n" + task_content + "\n" +
        feedback_section + "\n" +
        scope_section
    )
    
    static_size = len(static_content)
    
    # Check if scope files + instructions alone exceed budget
    if static_size > total_budget_chars:
        print(
            f"ERROR: Scoped files and task description ({static_size} chars ≈ {static_size//4} tokens) "
            f"exceed the token budget ({total_budget_chars} chars ≈ {int(total_budget_chars//4)} tokens).\n"
            f"Please use patch mode (--mode patch), or split this task into smaller sub-tasks!",
            file=sys.stderr
        )
        sys.exit(1)

    # Allocate remaining budget
    remaining_budget = total_budget_chars - static_size
    
    # If repo map is present, subtract it
    repo_map_str = ""
    if repo_map and len(repo_map) < remaining_budget * 0.3: # Allocate max 30% of remaining budget to repo map
        repo_map_str = f"\n\n=== REPOSITORY MAP ===\n{repo_map}\n"
        remaining_budget -= len(repo_map_str)
    
    # Read and truncate Reference Files
    context_section_lines = []
    if context_section_dict:
        # Divide remaining budget equally among reference files
        file_budget = remaining_budget // len(context_section_dict)
        if file_budget < 500: # Too small, truncating heavily
            file_budget = 500
            
        for cf, content in context_section_dict.items():
            truncated_content, was_truncated = truncate_text(content, file_budget)
            context_section_lines.append(
                f"\n=== REFERENCE FILE (READ-ONLY): {cf} ===\n{truncated_content}"
            )
            
    context_section = "".join(context_section_lines)
    
    # Combine final prompt
    final_prompt = (
        f"{system_instruction}\n\n"
        f"{output_format}\n\n"
        f"TASK:\n"
        f"{task_content}\n"
        f"{feedback_section}"
        f"{repo_map_str}"
        f"{context_section}\n"
        f"\nCURRENT FILES (Scope write-access allowed):\n"
        f"{scope_section}"
    )
    
    print(final_prompt)
    sys.exit(0)

def main():
    # Parse inputs from CLI or Env
    project_root = sys.argv[1]
    task_file = sys.argv[2]
    attempt_num = int(sys.argv[3])
    max_attempts = int(sys.argv[4])
    feedback_file = sys.argv[5] if len(sys.argv) > 5 else None
    
    # Read feedback if exists
    feedback_text = ""
    if feedback_file and os.path.exists(feedback_file):
        with open(feedback_file, "r") as f:
            feedback_text = f.read()

    # Load parameters from environment variables (exported by common.sh)
    active_mode = os.environ.get("SIA_RUN_MODE", "worker")
    num_ctx = int(os.environ.get("SIA_ACTIVE_NUM_CTX", 16384))
    budget_pct = int(os.environ.get("SIA_CONTEXT_BUDGET_PCT", 80))
    include_repo_map = os.environ.get("SIA_CONTEXT_REPO_MAP", "true").lower() == "true"
    repo_map_max_files = int(os.environ.get("SIA_CONTEXT_REPO_MAP_MAX_FILES", 400))
    
    exclude_dirs_str = os.environ.get("SIA_EXCLUDE_DIRS", "")
    exclude_dirs = exclude_dirs_str.split() if exclude_dirs_str else []

    build_prompt(
        project_root=project_root,
        task_file=task_file,
        attempt_num=attempt_num,
        max_attempts=max_attempts,
        feedback_text=feedback_text,
        active_mode=active_mode,
        num_ctx=num_ctx,
        budget_pct=budget_pct,
        include_repo_map=include_repo_map,
        repo_map_max_files=repo_map_max_files,
        exclude_dirs=exclude_dirs
    )

if __name__ == "__main__":
    main()
