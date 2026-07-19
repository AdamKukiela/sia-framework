#!/usr/bin/env python3
# /// script
# requires-python = ">=3.13"
# ///
import sys
import argparse
import subprocess
import signal
import os
from pathlib import Path

def run_command(cmd_args: list[str], timeout: int | None = None, sandbox_mode: str = "none", docker_image: str = "node:20") -> int:
    cwd = Path.cwd()
    # Join command parts back into a single command executable by shell (bash -c)
    shell_cmd = " ".join(cmd_args)
    
    if sandbox_mode == "docker":
        uid = os.getuid()
        gid = os.getgid()
        cmd_to_run = [
            "docker", "run", "--rm",
            "--network", "none",
            "-v", f"{cwd}:/work",
            "-w", "/work",
            "--user", f"{uid}:{gid}",
            docker_image,
            "bash", "-c", shell_cmd
        ]
    elif sandbox_mode == "sandbox-exec" and sys.platform == "darwin":
        # Resolve template path dynamically relative to run_cmd.py location
        script_dir = Path(__file__).resolve().parent
        sb_profile = script_dir.parents[1] / "templates" / "sia.sb"
        
        if not sb_profile.exists():
            # Insecure fallback warning
            print(f"[run_cmd.py] WARNING: {sb_profile} not found. Creating local permissive profile.", file=sys.stderr)
            sb_profile = Path("/tmp/sia_temp.sb")
            sb_profile.write_text("(version 1)\n(allow default)\n", encoding="utf-8")
            
        cmd_to_run = ["sandbox-exec", "-f", str(sb_profile), "bash", "-c", shell_cmd]
    else:
        cmd_to_run = ["bash", "-c", shell_cmd]

    p = None
    try:
        p = subprocess.Popen(
            cmd_to_run,
            stdout=sys.stdout,
            stderr=sys.stderr,
            preexec_fn=os.setsid if sys.platform != "win32" else None
        )
        p.wait(timeout=timeout)
        return p.returncode
    except subprocess.TimeoutExpired:
        print(f"\n[run_cmd.py] TIMEOUT: Command expired after {timeout} seconds. Killing process tree...", file=sys.stderr)
        if p:
            if sys.platform != "win32":
                try:
                    os.killpg(os.getpgid(p.pid), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            else:
                p.kill()
        return 124
    except Exception as e:
        print(f"\n[run_cmd.py] ERROR executing command: {e}", file=sys.stderr)
        return 3

def main():
    parser = argparse.ArgumentParser(description="Run command with timeout and sandbox constraints")
    parser.add_argument("--timeout", type=int, default=600, help="Timeout in seconds")
    parser.add_argument("--sandbox", choices=["none", "sandbox-exec", "docker"], default="none", help="Sandbox mode")
    parser.add_argument("--docker-image", default="node:20", help="Docker image to use for docker sandbox")
    
    args_list = sys.argv[1:]
    if "--" in args_list:
        sep_idx = args_list.index("--")
        our_args = args_list[:sep_idx]
        cmd_args = args_list[sep_idx+1:]
    else:
        our_args = args_list
        cmd_args = []
        
    parsed_args = parser.parse_args(our_args)
    if not cmd_args:
        print("ERROR: Command to run must be specified after '--'", file=sys.stderr)
        sys.exit(2)
        
    rc = run_command(
        cmd_args=cmd_args,
        timeout=parsed_args.timeout,
        sandbox_mode=parsed_args.sandbox,
        docker_image=parsed_args.docker_image
    )
    sys.exit(rc)

if __name__ == "__main__":
    main()
