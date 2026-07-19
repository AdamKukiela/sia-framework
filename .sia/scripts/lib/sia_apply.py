#!/usr/bin/env python3
# /// script
# requires-python = ">=3.13"
# ///
import sys
import re
from pathlib import Path

def parse_blocks(response_text: str) -> dict[str, list[tuple[str, str]]]:
    file_blocks = {}
    current_file = None
    lines = response_text.splitlines(keepends=True)
    
    i = 0
    while i < len(lines):
        line = lines[i]
        match = re.match(r"^===\s*FILE:\s*(.+?)\s*===\s*$", line.strip())
        if match:
            current_file = match.group(1).strip()
            file_blocks[current_file] = []
            i += 1
            continue
            
        if current_file:
            if line.strip().startswith("<<<<<<< SEARCH"):
                search_lines = []
                replace_lines = []
                i += 1
                while i < len(lines) and not lines[i].strip().startswith("======="):
                    search_lines.append(lines[i])
                    i += 1
                if i < len(lines) and lines[i].strip().startswith("======="):
                    i += 1
                    while i < len(lines) and not lines[i].strip().startswith(">>>>>>> REPLACE"):
                        replace_lines.append(lines[i])
                        i += 1
                if i < len(lines) and lines[i].strip().startswith(">>>>>>> REPLACE"):
                    search_text = "".join(search_lines)
                    replace_text = "".join(replace_lines)
                    file_blocks[current_file].append((search_text, replace_text))
        i += 1
    return file_blocks

def apply_patches(patch_file: str, scope_files: list[str]) -> int:
    patch_path = Path(patch_file)
    if not patch_path.exists():
        print(f"ERROR: Patch file {patch_file} not found.", file=sys.stderr)
        return 1
        
    response_text = patch_path.read_text(encoding="utf-8")
    file_blocks = parse_blocks(response_text)
    if not file_blocks:
        print("ERROR: No valid FILE headers or SEARCH/REPLACE blocks found in model output.", file=sys.stderr)
        return 1

    project_root = Path.cwd().resolve()
    
    # Path Traversal & Scope Validation (Hardened)
    for file_path_str in file_blocks.keys():
        try:
            # Resolving components to absolute paths, bypassing tricks like symlinks & parent directory traversal
            target_path = (project_root / file_path_str).resolve()
        except Exception as e:
            print(f"VIOLATION: Invalid target path format '{file_path_str}': {e}", file=sys.stderr)
            return 2

        # Ensure target is strictly inside project root (anti-traversal)
        if project_root not in target_path.parents and target_path != project_root:
            print(f"VIOLATION: Path traversal attempt blocked: {file_path_str}", file=sys.stderr)
            return 2
            
        in_scope = False
        for s_file in scope_files:
            scope_path = (project_root / s_file).resolve()
            if s_file.endswith("/"):
                # Directory scope check
                if scope_path in target_path.parents or target_path == scope_path:
                    in_scope = True
                    break
            else:
                # Exact file scope check
                if target_path == scope_path:
                    in_scope = True
                    break
                    
        if not in_scope:
            print(f"VIOLATION: Model attempted to modify file outside scope: {file_path_str}", file=sys.stderr)
            return 2

    modifications = {}
    for file_path_str, blocks in file_blocks.items():
        file_path = (project_root / file_path_str).resolve()
        content = file_path.read_text(encoding="utf-8") if file_path.exists() else ""
        temp_content = content
        
        for idx, (search_text, replace_text) in enumerate(blocks):
            if not search_text:
                if not temp_content:
                    temp_content = replace_text
                else:
                    temp_content += "\n" + replace_text
                continue
                
            count = temp_content.count(search_text)
            if count == 0:
                print(f"ERROR in {file_path_str} (Block #{idx+1}): SEARCH block not found.", file=sys.stderr)
                return 1
            elif count > 1:
                print(f"ERROR in {file_path_str} (Block #{idx+1}): SEARCH block matches {count} times.", file=sys.stderr)
                return 1
                
            temp_content = temp_content.replace(search_text, replace_text, 1)
        modifications[file_path] = temp_content

    for file_path, new_content in modifications.items():
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_text(new_content, encoding="utf-8")
        print(f"Successfully applied patches to: {file_path.relative_to(project_root)}")
    return 0

def main():
    if len(sys.argv) < 3:
        print("Usage: sia_apply.py <patch_file_path> <scope_file_1> ...", file=sys.stderr)
        sys.exit(1)
    rc = apply_patches(sys.argv[1], sys.argv[2:])
    sys.exit(rc)

if __name__ == "__main__":
    main()
