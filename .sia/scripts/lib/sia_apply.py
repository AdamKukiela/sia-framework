#!/usr/bin/env python3
import sys
import os
import re

def parse_blocks(response_text):
    """
    Parses file blocks and SEARCH/REPLACE blocks.
    Returns: { file_path: [ (search_text, replace_text) ] }
    """
    file_blocks = {}
    current_file = None
    lines = response_text.splitlines(keepends=True)
    
    i = 0
    while i < len(lines):
        line = lines[i]
        # Match file header
        match = re.match(r"^===\s*FILE:\s*(.+?)\s*===\s*$", line.strip())
        if match:
            current_file = match.group(1).strip()
            file_blocks[current_file] = []
            i += 1
            continue
            
        if current_file:
            # Check for SEARCH block start
            if line.strip().startswith("<<<<<<< SEARCH"):
                search_lines = []
                replace_lines = []
                
                # Consume search
                i += 1
                while i < len(lines) and not lines[i].strip().startswith("======="):
                    search_lines.append(lines[i])
                    i += 1
                    
                # Consume replace
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

def apply_patches(patch_file, scope_files):
    if not os.path.exists(patch_file):
        print(f"ERROR: Patch file {patch_file} not found.", file=sys.stderr)
        return 1
        
    with open(patch_file, "r") as f:
        response_text = f.read()
        
    file_blocks = parse_blocks(response_text)
    if not file_blocks:
        print("ERROR: No valid FILE headers or SEARCH/REPLACE blocks found in model output.", file=sys.stderr)
        return 1

    # Verify Scope
    for file_path in file_blocks.keys():
        in_scope = False
        for s_file in scope_files:
            if s_file.endswith("/"):
                if file_path.startswith(s_file):
                    in_scope = True
                    break
            elif file_path == s_file:
                in_scope = True
                break
        if not in_scope:
            print(f"VIOLATION: Model attempted to modify file outside scope: {file_path}", file=sys.stderr)
            return 2 # Scope violation code

    # Test all patches first (dry run) to make it atomic
    modifications = {}
    
    for file_path, blocks in file_blocks.items():
        if not os.path.exists(file_path):
            # If file doesn't exist, we assume SEARCH block must be empty or we create a new file
            # Most local models assume empty search block for new file
            content = ""
        else:
            with open(file_path, "r") as f:
                content = f.read()
                
        temp_content = content
        for idx, (search_text, replace_text) in enumerate(blocks):
            # If search_text is empty, we just append or write to file
            if not search_text:
                if not temp_content:
                    temp_content = replace_text
                else:
                    # Append at the end if SEARCH is empty and file exists
                    temp_content += "\n" + replace_text
                continue
                
            # Count occurrences of search_text
            count = temp_content.count(search_text)
            if count == 0:
                print(f"ERROR in {file_path} (Block #{idx+1}): SEARCH block not found in file.", file=sys.stderr)
                print(f"--- SEARCH BLOCK TRUNCATED ---", file=sys.stderr)
                print(search_text[:200] + ("..." if len(search_text) > 200 else ""), file=sys.stderr)
                return 1
            elif count > 1:
                print(f"ERROR in {file_path} (Block #{idx+1}): SEARCH block matches multiple times ({count} occurrences). Please make the SEARCH block more unique.", file=sys.stderr)
                return 1
                
            temp_content = temp_content.replace(search_text, replace_text, 1)
            
        modifications[file_path] = temp_content

    # Apply all modifications
    for file_path, new_content in modifications.items():
        # Ensure parent directory exists
        os.makedirs(os.path.dirname(file_path) or ".", exist_ok=True)
        with open(file_path, "w") as f:
            f.write(new_content)
        print(f"Successfully applied patches to: {file_path}")
        
    return 0

def main():
    if len(sys.argv) < 3:
        print("Usage: sia_apply.py <patch_file_path> <scope_file_1> [scope_file_2 ...]", file=sys.stderr)
        sys.exit(1)
        
    patch_file = sys.argv[1]
    scope_files = sys.argv[2:]
    
    rc = apply_patches(patch_file, scope_files)
    sys.exit(rc)

if __name__ == "__main__":
    main()
