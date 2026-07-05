#!/usr/bin/env python3
import sys
import os
import argparse
import subprocess
import signal
import time

def run_command(cmd, timeout=None, sandbox_mode="none", docker_image="node:20"):
    cwd = os.getcwd()
    
    if sandbox_mode == "docker":
        # Build docker command
        uid = os.getuid()
        gid = os.getgid()
        docker_cmd = [
            "docker", "run", "--rm",
            "--network", "none",
            "-v", f"{cwd}:/work",
            "-w", "/work",
            "--user", f"{uid}:{gid}",
            docker_image
        ]
        # Append the command (e.g. bash -c "...")
        docker_cmd.extend(cmd)
        cmd_to_run = docker_cmd
    elif sandbox_mode == "sandbox-exec" and sys.platform == "darwin":
        # macOS native sandbox
        sb_profile = os.path.join(cwd, "templates", "sia.sb")
        if not os.path.exists(sb_profile):
            # Fallback inline temporary profile if not found
            sb_profile = "/tmp/sia_temp.sb"
            with open(sb_profile, "w") as f:
                f.write("(version 1)\n(allow default)\n")
        cmd_to_run = ["sandbox-exec", "-f", sb_profile] + cmd
    else:
        cmd_to_run = cmd

    # Run with process group to enable killing children on timeout
    p = None
    try:
        # os.setsid creates a process group so we can kill all child processes
        p = subprocess.Popen(
            cmd_to_run,
            stdout=sys.stdout,
            stderr=sys.stderr,
            preexec_fn=os.setsid if sys.platform != "win32" else None
        )
        
        # Wait with timeout
        p.wait(timeout=timeout)
        return p.returncode
    except subprocess.TimeoutExpired:
        print(f"\n[run_cmd.py] TIMEOUT: Command expired after {timeout} seconds. Killing process tree...", file=sys.stderr)
        if p:
            if sys.platform != "win32":
                try:
                    # Kill the whole process group
                    os.killpg(os.getpgid(p.pid), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            else:
                p.kill()
        return 124  # Standard timeout exit code
    except Exception as e:
        print(f"\n[run_cmd.py] ERROR executing command: {e}", file=sys.stderr)
        return 3

def main():
    parser = argparse.ArgumentParser(description="Run command with timeout and sandbox constraints")
    parser.add_argument("--timeout", type=int, default=600, help="Timeout in seconds")
    parser.add_argument("--sandbox", choices=["none", "sandbox-exec", "docker"], default="none", help="Sandbox mode")
    parser.add_argument("--docker-image", default="node:20", help="Docker image to use for docker sandbox")
    
    # Locate '--' separating our options from the actual command
    args_list = sys.argv[1:]
    if "--" in args_list:
        sep_idx = args_list.index("--")
        our_args = args_list[:sep_idx]
        cmd_args = args_list[sep_idx+1:]
    else:
        # Fallback if no '--' provided
        # Find the first argument that does not start with '-' and is not a value of a previous arg
        # To be safe, we strongly recommend '--'
        our_args = args_list
        cmd_args = []
        
    parsed_args = parser.parse_args(our_args)
    if not cmd_args:
        print("ERROR: Command to run must be specified after '--'", file=sys.stderr)
        sys.exit(2)
        
    rc = run_command(
        cmd=cmd_args,
        timeout=parsed_args.timeout,
        sandbox_mode=parsed_args.sandbox,
        docker_image=parsed_args.docker_image
    )
    sys.exit(rc)

if __name__ == "__main__":
    main()
