#!/usr/bin/env python3
"""Capture a supplied Herdr 0.9.0 binary's real UI without agents or models.

Development dependency: pyte 0.8.2. The caller supplies an independently
verified native binary; this script never downloads or installs Herdr.
"""

import argparse
import codecs
import fcntl
import json
import os
from pathlib import Path
import platform
import pty
import re
import select
import shlex
import struct
import subprocess
import sys
import tempfile
import termios
import time

import pyte


ROOT = Path(__file__).resolve().parents[2]
COLS, ROWS = 140, 32
PALETTE = ["272e33", "e67e80", "a7c080", "dbbc7f", "7fbbb3", "d699b6",
           "83c092", "d3c6aa", "7a8478", "e67e80", "a7c080", "dbbc7f",
           "7fbbb3", "d699b6", "83c092", "dfddc7"]


class CaptureScreen(pyte.Screen):
    # Query replies are written to the real PTY by answer_queries below. pyte
    # 0.8.2's default callbacks cannot accept Herdr's private query variants.
    def report_device_status(self, mode=0, **kwargs):
        pass

    def report_device_attributes(self, mode=0, **kwargs):
        pass


def answer_queries(master, chunk):
    def rgb(value):
        return "/".join(value[index:index + 2] * 2 for index in (0, 2, 4)).encode()

    for match in re.finditer(rb"\x1b\](10|11);\?(?:\x07|\x1b\\)", chunk):
        code = match[1]
        value = "d3c6aa" if code == b"10" else "272e33"
        os.write(master, b"\x1b]" + code + b";rgb:" + rgb(value) + b"\x1b\\")
    for match in re.finditer(rb"\x1b\]4;(\d+);\?(?:\x07|\x1b\\)", chunk):
        index = int(match[1])
        if index < len(PALETTE):
            os.write(master, b"\x1b]4;" + match[1] + b";rgb:" + rgb(PALETTE[index]) + b"\x1b\\")
    if b"\x1b[6n" in chunk:
        os.write(master, b"\x1b[1;1R")
    if b"\x1b[c" in chunk:
        os.write(master, b"\x1b[?1;2c")


def capture(binary, base):
    home = base / "home"
    config_dir = home / ".config/local-ai/herdr"
    local_bin = home / ".local/bin"
    for path in (config_dir, local_bin, home / "github/golf-game",
                 home / "github/coding-project"):
        path.mkdir(parents=True, mode=0o700)
    config = config_dir / "config.toml"
    config.write_text('''onboarding = false
[theme]
name = "terminal"
[session]
resume_agents_on_restore = false
[terminal]
default_shell = "/bin/bash"
shell_mode = "non_login"
kitty_graphics = false
[update]
version_check = false
manifest_check = false
[server]
headless_cols = 140
headless_rows = 32
''')
    (home / ".bashrc").write_text("PS1='\\[\\e[32m\\]\\w \\[\\e[36m\\]❯ \\[\\e[0m\\]'\n")
    # Deliberately whitelist the environment; no host agent credentials, user
    # dotfiles, Herdr session, or inherited API socket enters the fixture.
    env = {
        "HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "SHELL": "/bin/bash", "BASH_SILENCE_DEPRECATION_WARNING": "1",
        "TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "en_US.UTF-8",
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_DATA_HOME": str(home / ".local/share"),
        "LOCAL_AI_CONFIG_DIR": str(config_dir.parent),
        "HERDR_CONFIG_DIR": str(config_dir), "HERDR_CONFIG_PATH": str(config),
        "LOCAL_BIN_DIR": str(local_bin),
    }
    version = subprocess.run([str(binary), "--version"], env=env, text=True,
                             capture_output=True, check=True, timeout=10).stdout.strip()
    if not re.search(r"\b0\.9\.0\b", version):
        raise RuntimeError(f"Capture expects reviewed Herdr 0.9.0, got {version!r}")
    wrapper = local_bin / "local-ai-herdr"
    wrapper.write_text('#!/bin/bash\nexec ' + shlex.quote(str(binary)) + ' --session local-ai "$@"\n')
    wrapper.chmod(0o700)

    def call(*args):
        result = subprocess.run([str(wrapper), *map(str, args)], env=env, text=True,
                                capture_output=True, timeout=15)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        return result.stdout

    client = None
    master = None
    try:
        for name, profile in (("coding-project", "coding"), ("golf-game", "golf")):
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/local-ai-workspace.py"), "open",
                 str(home / "github" / name), "--profile", profile, "--no-agent", "--no-attach"],
                env=env, text=True, capture_output=True, timeout=45)
            if result.returncode:
                raise RuntimeError(result.stdout + result.stderr)
        workspaces = json.loads(call("workspace", "list"))["result"]["workspaces"]
        golf_id = None
        for workspace in workspaces:
            profile = workspace.get("tokens", {}).get("local_ai_profile")
            if profile in ("coding", "golf"):
                # UI labels are user-editable; keep fixture labels legible while
                # retaining the actual canonical-path/profile ownership tokens.
                name = "golf-game" if profile == "golf" else "coding-project"
                call("workspace", "rename", workspace["workspace_id"], name)
                if profile == "golf":
                    golf_id = workspace["workspace_id"]
        if golf_id is None:
            raise RuntimeError("The real workspace helper did not create its golf profile")
        panes = json.loads(call("pane", "list", "--workspace", golf_id))["result"]["panes"]

        def role(name):
            return next(pane for pane in panes if pane.get("tokens", {}).get("local_ai_role") == name)

        # Literal fixture text in real shells. This is never presented as agent
        # output, a completed build, or a model/hardware validation result.
        call("pane", "run", role("physics")["pane_id"],
             "clear; printf '\\nPhysics workspace\\nBall dynamics / surface friction / tests\\n\\nNo agent started in this preview.\\n'")
        call("pane", "run", role("course")["pane_id"],
             "clear; printf '\\nCourse workspace\\nHole layout / terrain / scoring\\n\\nReady for an explicit project task.\\n'")
        call("workspace", "focus", golf_id)
        call("tab", "focus", role("physics")["tab_id"])
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        try:
            client = subprocess.Popen([str(wrapper)], env=env, stdin=slave, stdout=slave,
                                      stderr=slave, start_new_session=True)
        finally:
            os.close(slave)
        screen = CaptureScreen(COLS, ROWS)
        stream = pyte.Stream(screen)
        decoder = codecs.getincrementaldecoder("utf-8")("replace")
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if not select.select([master], [], [], 0.1)[0]:
                continue
            chunk = os.read(master, 65536)
            if not chunk:
                break
            answer_queries(master, chunk)
            stream.feed(decoder.decode(chunk))
        visible = "\n".join(screen.display)
        if "Simulation" not in visible or "Physics workspace" not in visible or "golf-game" not in visible:
            raise RuntimeError("Herdr did not display the expected real workspace:\n" + visible)
        return {
            "version": version,
            "platform": "macOS" if platform.system() == "Darwin" else platform.system(),
            "cells": [[screen.buffer[y][x]._asdict() for x in range(COLS)] for y in range(ROWS)],
            "display": screen.display,
        }
    finally:
        # Stop only this fixture's named server via its private environment.
        # Stopping before closing the PTY also avoids leaving pane shells alive.
        try:
            try:
                call("server", "stop")
            except RuntimeError as error:
                if "server is not running" not in str(error):
                    raise
        finally:
            if master is not None:
                os.close(master)
            if client is not None:
                try:
                    client.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    client.kill()
                    client.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path, help="Reviewed native Herdr 0.9.0 executable")
    args = parser.parse_args()
    binary = args.binary.expanduser().resolve(strict=True)
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error("--binary must point to an executable file")
    # macOS's usual TMPDIR is too long for Herdr's Unix-domain socket path.
    with tempfile.TemporaryDirectory(prefix="herdr-docs-", dir="/tmp") as temporary:
        result = capture(binary, Path(temporary).resolve())
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
