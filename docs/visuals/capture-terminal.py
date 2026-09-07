#!/usr/bin/env python3
"""Capture the real read-only CLI in an empty, isolated documentation home."""

import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time


ROOT = Path(__file__).resolve().parents[2]


def terminal(argv, env, interactive=False):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 60, 120, 0, 0))
    process = subprocess.Popen(
        argv, cwd=ROOT, env=env, stdin=slave, stdout=slave, stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    chunks = bytearray()
    captured = None
    deadline = time.monotonic() + 30
    try:
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    data = os.read(master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not data:
                    break
                chunks.extend(data)
                if interactive and captured is None and b"select > " in chunks:
                    captured = bytes(chunks)
                    os.write(master, b"q\n")
            elif process.poll() is not None:
                break
        else:
            raise RuntimeError("CLI capture timed out:\n" + chunks.decode(errors="replace"))
        result = process.wait(timeout=5)
        expected = 0 if interactive else 1  # An empty pre-install plan has gates.
        if result != expected or (interactive and captured is None):
            raise RuntimeError(f"Unexpected CLI capture exit {result}:\n{chunks.decode(errors='replace')}")
        return (captured if captured is not None else bytes(chunks)).decode().replace("\r\n", "\n")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


def main():
    with tempfile.TemporaryDirectory(prefix="local-ai-docs-") as temp:
        fixture = Path(temp)
        home = fixture / "home"
        tools = fixture / "bin"
        runtime = fixture / "runtime"
        omarchy = fixture / "omarchy"
        for folder in (home, tools, runtime, omarchy):
            folder.mkdir(mode=0o700)

        # Only these utilities are visible: no host coding agents, llama-server,
        # package manager, sudo, or service manager can be invoked by a capture.
        utilities = (
            "bash", "dirname", "cat", "awk", "sed", "grep", "jq", "uname",
            "sort", "head", "tail", "tr", "cut", "wc", "find", "stat", "id",
            "readlink", "realpath", "date", "sha256sum", "shasum", "python3",
        )
        for name in utilities:
            executable = shutil.which(name)
            if executable:
                (tools / name).symlink_to(executable)
        for required in ("bash", "jq", "awk", "sed", "grep"):
            if not (tools / required).exists():
                sys.exit(f"Required capture utility is missing: {required}")

        # The status probe sees a stopped service and an unreachable API. These
        # stubs cannot contact the user's localhost or change a real service.
        stubs = {
            "systemctl": 'case "$*" in *--quiet*) ;; *) printf \'inactive\\n\' ;; esac\nexit 3\n',
            "curl": "printf '000'\nexit 7\n",
            "clear": "exit 0\n",
        }
        for name, body in stubs.items():
            target = tools / name
            target.write_text("#!/usr/bin/env bash\n" + body)
            target.chmod(0o700)
        (fixture / "os-release").write_text('ID=arch\nPRETTY_NAME="Documentation fixture"\n')
        (omarchy / "version").write_text("documentation-fixture\n")
        env = {
            "PATH": str(tools), "HOME": str(home), "LANG": "en_US.UTF-8",
            "TERM": "xterm-256color", "LOCAL_AI_MENU": "plain",
            "XDG_RUNTIME_DIR": str(runtime), "XDG_DATA_HOME": str(home / ".local/share"),
            "LOCAL_AI_CONFIG_DIR": str(home / ".config/local-ai"),
            "LOCAL_BIN_DIR": str(home / ".local/bin"),
            "MODELS_DIR": str(home / "llm/models"),
            "LOCAL_AI_OS_RELEASE": str(fixture / "os-release"),
            "OMARCHY_PATH": str(omarchy), "MODEL_LOCK": str(ROOT / "models.lock"),
        }
        captures = {}
        for name, args in (("local-ai-menu", []), ("local-ai-plan", ["plan"])):
            output = terminal([str(tools / "bash"), "./local-ai", *args], env, not args)
            # Normalize ephemeral paths for a stable, readable documentation view.
            output = output.replace(str(home), "~").replace(str(ROOT), "~/github/local-ai-setup")
            captures[name] = {"command": "./local-ai" + (" plan" if args else ""), "output": output}
        print(json.dumps(captures, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
