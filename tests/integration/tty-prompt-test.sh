#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="$ROOT/setup-qwen38-pi.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-tty-test.XXXXXX")"

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
# saved child status via wait(PID), not turn a successful fast mutation into 1.
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
PY

printf 'Controlling-TTY prompt integration test passed.\n'
