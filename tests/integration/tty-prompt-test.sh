#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/setup-qwen38-pi.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-tty-test.XXXXXX")"
# shellcheck source=../lib/environment.sh
source "$ROOT/tests/lib/environment.sh"

cleanup() {
  [[ "$TEST_TMP" == */local-ai-tty-test.* ]] || return 1
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT

command -v python3 >/dev/null 2>&1 || {
  printf 'FAIL: python3 is required for the controlling-TTY regression test\n' >&2
  exit 1
}
mkdir -p "$TEST_TMP/home" "$TEST_TMP/runtime"
chmod 700 "$TEST_TMP/runtime"

python3 - "$ENGINE" "$ROOT/models.lock" "$TEST_TMP" <<'PY'
import os
import pty
import select
import signal
import sys
import time

engine, lock_file, test_tmp = sys.argv[1:]
env = os.environ.copy()
env.update({
    "HOME": os.path.join(test_tmp, "home"),
    "TMPDIR": os.path.join(test_tmp, "runtime"),
    "MODEL_LOCK": lock_file,
    "LOCAL_AI_CONFIG_DIR": os.path.join(test_tmp, "config"),
    "MODELS_DIR": os.path.join(test_tmp, "models"),
})

pid, fd = pty.fork()
if pid == 0:
    os.execve(engine, [engine, "model", "all"], env)

output = bytearray()
answered = False
status = None
deadline = time.monotonic() + 10
try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                chunk = b""
            output.extend(chunk)
            if not answered and b"Download all pinned artifacts? [y/N]" in output:
                os.write(fd, b"n\n")
                answered = True
        waited, candidate = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            status = candidate
            break
finally:
    if status is None:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
    os.close(fd)

text = output.decode("utf-8", "replace")
if not answered:
    raise SystemExit("FAIL: mutating command never presented its controlling-TTY confirmation\n" + text)
if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
    raise SystemExit(f"FAIL: confirmation response did not complete cleanly (status={status})\n{text}")
if "Skipped." not in text:
    raise SystemExit("FAIL: negative confirmation was not consumed by the foreground mutation\n" + text)

# Force the lifecycle child to finish before the parent's fg builtin runs.
# Bash removes a completed job from `%%`; the engine must still return the
# saved child status, not turn a successful fast mutation into 1.
fg_env = os.path.join(test_tmp, "delayed-fg.bash")
with open(fg_env, "w", encoding="utf-8") as handle:
    handle.write('fg() { /bin/sleep 0.25; builtin fg "$@"; }\n')
fast_env = env.copy()
fast_env["BASH_ENV"] = fg_env
pid, fd = pty.fork()
if pid == 0:
    os.execve(engine, [engine, "save-config", "AGENT=omp"], fast_env)

output = bytearray()
status = None
deadline = time.monotonic() + 10
try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                output.extend(os.read(fd, 4096))
            except OSError:
                pass
        waited, candidate = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            status = candidate
            break
finally:
    if status is None:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
    os.close(fd)

if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
    text = output.decode("utf-8", "replace")
    raise SystemExit(f"FAIL: completed foreground job lost its exit status (status={status})\n{text}")
if not os.path.isfile(os.path.join(test_tmp, "config", "setup.env")):
    raise SystemExit("FAIL: fast foreground mutation did not persist configuration")

# In Bash 5.2, successful foregrounding can consume wait(PID)'s saved status.
# Conversely, a job already gone before fg can really have exited 127. Keep
# those cases distinct rather than treating every wait=127 as an fg fallback.
def status_fixture(expected, delayed_fg=False, interrupt=False):
    fixture_env = env.copy()
    fixture_env["LOCAL_AI_SETUP_LIB_ONLY"] = "1"
    if delayed_fg:
        fixture_env["BASH_ENV"] = fg_env
    script = '''source "$1"
expected_status="$2"
completion_delay="$3"
interrupt_mode="$4"
fixture() {
  if [[ "$interrupt_mode" == 1 ]]; then
    trap 'exit 130' TERM
    read -r -p "FOREGROUND_SIGNAL_READY: " answer
  else
    /bin/sleep "$completion_delay"
    return "$expected_status"
  fi
}
locked_command fixture
'''
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe("bash", ["bash", "-c", script, "_", engine, str(expected),
                            "0" if delayed_fg else "0.05", "1" if interrupt else "0"], fixture_env)
    output = bytearray()
    status = None
    sent_interrupt = False
    deadline = time.monotonic() + 10
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                try:
                    output.extend(os.read(fd, 4096))
                except OSError:
                    pass
                if interrupt and not sent_interrupt and b"FOREGROUND_SIGNAL_READY:" in output:
                    os.killpg(os.tcgetpgrp(fd), signal.SIGTERM)
                    sent_interrupt = True
            waited, candidate = os.waitpid(pid, os.WNOHANG)
            if waited == pid:
                status = candidate
                break
    finally:
        if status is None:
            os.kill(pid, signal.SIGKILL)
            _, status = os.waitpid(pid, 0)
        os.close(fd)
    text = output.decode("utf-8", "replace")
    if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != expected:
        raise SystemExit(f"FAIL: foreground status {expected} changed (delayed_fg={delayed_fg}, "
                         f"interrupt={interrupt}, status={status})\n{text}")
    if "not a child of this shell" in text:
        raise SystemExit("FAIL: expected fg/wait race leaked a diagnostic\n" + text)
    if os.path.exists(os.path.join(test_tmp, "runtime", f"local-ai-setup-{os.getuid()}.lock")):
        raise SystemExit("FAIL: foreground completion retained its lifecycle lock")

for delayed in (False, True):
    for expected in (0, 1, 127):
        status_fixture(expected, delayed_fg=delayed)
status_fixture(130, interrupt=True)
PY

printf 'Controlling-TTY prompt integration test passed.\n'
