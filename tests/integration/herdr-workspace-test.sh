#!/usr/bin/env bash
# Black-box orchestration checks against an offline native-shaped Herdr fixture.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-herdr-workspace-test.XXXXXX")"
cleanup() {
  [[ "$TEST_TMP" == */local-ai-herdr-workspace-test.* ]] || return 1
  rm -rf -- "$TEST_TMP"
}
trap cleanup EXIT
export ROOT TEST_TMP
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys

root = Path(os.environ["ROOT"])
temp = Path(os.environ["TEST_TMP"]).resolve()
script = root / "scripts/local-ai-workspace.py"
fixture = root / "tests/fixtures/herdr-mock.py"
case_number = 0
server_pids = []


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def passed(message):
    print("ok - " + message, flush=True)


def new_case():
    global case_number
    case_number += 1
    case = temp / str(case_number)
    case.mkdir()
    home, config, bindir = case / "home", case / "config", case / "bin"
    for path in (home, config / "herdr", bindir):
        path.mkdir(parents=True, exist_ok=True)
    wrapper = bindir / "local-ai-herdr"
    wrapper.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(fixture)) + ' "$@"\n')
    wrapper.chmod(0o700)
    agent = bindir / "local-ai-agent"
    agent.write_text("#!/bin/sh\nexit 0\n")
    agent.chmod(0o700)
    (config / "herdr/config.toml").write_text("# Managed by local-ai-setup: Herdr config\nonboarding = false\n")
    state_path = case / "mock.json"
    state_path.write_text(json.dumps({"running": True, "version": "0.9.0"}))
    env = dict(os.environ, HOME=str(home), LOCAL_AI_CONFIG_DIR=str(config),
               HERDR_CONFIG_DIR=str(config / "herdr"), HERDR_VERSION="0.9.0",
               LOCAL_BIN_DIR=str(bindir), HERDR_MOCK_STATE=str(state_path),
               XDG_CONFIG_HOME=str(home / ".config"), XDG_STATE_HOME=str(home / ".local/state"),
               PATH=str(bindir) + os.pathsep + os.environ["PATH"])
    for key in ("HERDR_SOCKET_PATH", "HERDR_CLIENT_SOCKET_PATH", "HERDR_PANE_ID", "HERDR_ENV"):
        env.pop(key, None)
    project = case / "project"
    project.mkdir()
    return case, project, state_path, env


def invoke(env, *args, success=True):
    result = subprocess.run([sys.executable, str(script), *map(str, args)], env=env,
                            capture_output=True, text=True, timeout=20)
    if (result.returncode == 0) != success:
        raise AssertionError(f"Unexpected return {result.returncode}: {args!r}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}")
    return result


def load(path):
    return json.loads(path.read_text())


def update(path, **values):
    value = load(path)
    value.update(values)
    path.write_text(json.dumps(value))


def open_project(env, project, profile="coding", success=True):
    return invoke(env, "open", project, "--profile", profile, "--no-agent", "--no-attach", success=success)


def mutations(state):
    return [call for call in state.get("calls", []) if call[:1] == ["server"] or
            (len(call) > 1 and call[1] in {"create", "split", "run", "prompt", "rename", "report-metadata"})]


try:
    case, project, state_path, env = new_case()
    open_project(env, project)
    first = load(state_path)
    check(len(first["workspaces"]) == 1, "First open should create one workspace")
    check(not first["runs"], "Opening shells must not guess build/test commands")
    pane_ids = {item["pane_id"] for item in first["panes"]}
    check(len(pane_ids) >= 3, "Coding profile should prepare project roles")
    open_project(env, project)
    reopened = load(state_path)
    check(len(reopened["workspaces"]) == 1, "Reopen duplicated workspace")
    check({item["pane_id"] for item in reopened["panes"]} == pane_ids, "Reopen replaced live panes")
    check(not reopened["runs"], "Reopen submitted an unrequested command")
    passed("Herdr project reopen preserves panes without running guessed commands")

    sibling = case / "elsewhere" / "project"
    sibling.mkdir(parents=True)
    open_project(env, sibling)
    isolated = load(state_path)
    check(len(isolated["workspaces"]) == 2, "Same basenames must remain separate projects")
    keys = {item["tokens"].get("local_ai_project") for item in isolated["workspaces"]}
    expected = {hashlib.sha256(str(path.resolve()).encode()).hexdigest() for path in (project, sibling)}
    check(keys == expected, "Workspace ownership must use canonical project identity")
    alias = case / "project-link"
    alias.symlink_to(project, target_is_directory=True)
    open_project(env, alias)
    check(len(load(state_path)["workspaces"]) == 2, "Project aliases duplicated the same canonical checkout")
    passed("Herdr project identity isolates same basenames and resolves checkout aliases")

    case, project, state_path, env = new_case()
    update(state_path, running=False)
    config_before = {str(path): path.read_bytes() for path in Path(env["LOCAL_AI_CONFIG_DIR"]).rglob("*") if path.is_file()}
    invoke(env, "list")
    invoke(env, "status", project)
    check(not mutations(load(state_path)), "Read-only status/list started or modified a server")
    config_after = {str(path): path.read_bytes() for path in Path(env["LOCAL_AI_CONFIG_DIR"]).rglob("*") if path.is_file()}
    check(config_before == config_after, "Read-only status/list wrote local configuration or registry state")
    passed("Herdr status and list are read-only without a running server")

    case, project, state_path, env = new_case()
    update(state_path, attach_check_lock=str(Path(env["HERDR_CONFIG_DIR"]) / "layout.lock"))
    invoke(env, "open", project, "--no-agent")
    check(load(state_path).get("attachments") == 1, "Opening the project did not attach")
    attached = subprocess.run(["bash", str(root / "local-ai"), "workspace", "attach", str(project)],
                              env=dict(env, MODEL_LOCK=str(case / "invalid-engine-model-lock")),
                              text=True, capture_output=True, timeout=10)
    check(attached.returncode == 0, "Front-door attach entered the model lifecycle or retained a registry lock:\n" + attached.stdout + attached.stderr)
    check(load(state_path).get("attachments") == 2, "Front-door attach did not reach its Herdr client")
    passed("Herdr attaches through the front door after releasing workspace locks")

    case, project, state_path, env = new_case()
    update(state_path, version="0.8.0")
    open_project(env, project, success=False)
    check(not mutations(load(state_path)), "An incompatible daemon was modified")
    passed("Herdr incompatible daemon fails before workspace mutation")

    case, project, state_path, env = new_case()
    for invalid in (case / "missing", "bad\nproject"):
        open_project(env, invalid, success=False)
    invoke(env, "open", project, "--profile", "missing", "--no-agent", "--no-attach", success=False)
    check(not mutations(load(state_path)), "Invalid input mutated Herdr")
    passed("Herdr rejects invalid projects and profiles before mutation")

    case, project, state_path, env = new_case()
    open_project(env, project)
    words = ["printf", "%s\\n", "a b", "$(touch never-created)", "semi;colon", "a'b", "--flag=value"]
    invoke(env, "run", "build", project, "--", *words)
    submitted = load(state_path)["runs"][-1]
    check(shlex.split(submitted["command"]) == ["cd", "--", str(project.resolve()), "&&", *words], "Project cwd or explicit argv was not shell-quoted exactly")
    check(not (project / "never-created").exists(), "Shell substitution ran in orchestrator")
    count = len(load(state_path)["runs"])
    update(state_path, busy_panes=[submitted["pane_id"]])
    invoke(env, "run", "build", project, "--", "echo", "must not run", success=False)
    check(len(load(state_path)["runs"]) == count, "Busy pane received typed shell input")
    passed("Herdr quotes explicit command argv and refuses occupied panes")

    case, project, state_path, env = new_case()
    open_project(env, project)
    update(state_path, shell_name="python3")
    invoke(env, "run", "build", project, "--", "echo", "not an interactive shell", success=False)
    check(not load(state_path)["runs"], "A process that exec-replaced the shell received typed commands")
    passed("Herdr rejects exec-replaced shells despite unchanged foreground pid")

    case, project, state_path, env = new_case()
    open_project(env, project)
    for control in ("\n", "\r", "\t", "\x1b", "\x7f"):
        invoke(env, "run", "build", project, "--", "printf", "bad" + control + "argument", success=False)
    check(not load(state_path)["runs"], "Terminal control bytes reached pane.run")
    passed("Herdr rejects terminal control bytes before terminal command submission")

    case, project, state_path, env = new_case()
    project = case / "project ' ; $(literal)"
    project.mkdir()
    open_project(env, project)
    drift = case / "different-project"
    drift.mkdir()
    drifting = load(state_path)
    for item in drifting["panes"]:
        if item.get("tokens", {}).get("local_ai_role") == "build":
            item["cwd"] = item["foreground_cwd"] = str(drift)
    state_path.write_text(json.dumps(drifting))
    words = ["printf", "%s", "quoted ' value; $(literal)"]
    invoke(env, "run", "build", project, "--", *words)
    command = load(state_path)["runs"][-1]["command"]
    check(shlex.split(command) == ["cd", "--", str(project.resolve()), "&&", *words], "Shell cwd drift changed where the command would execute")
    passed("Herdr anchors shell commands to the project after pane cwd drift")

    case, project, state_path, env = new_case()
    update(state_path, fail_command="pane split", fail_remaining=1)
    open_project(env, project, success=False)
    partial = load(state_path)
    check(partial["panes"], "Failed layout should preserve already-created terminals")
    previous_ids = {item["pane_id"] for item in partial["panes"]}
    open_project(env, project)
    repaired = load(state_path)
    check(len(repaired["workspaces"]) == 1, "Partial retry duplicated workspace")
    check(previous_ids <= {item["pane_id"] for item in repaired["panes"]}, "Partial retry destroyed original terminals")
    check(not repaired["runs"], "Partial retry replayed commands")
    passed("Herdr repairs a partial layout without destroying panes or replaying work")

    case, project, state_path, env = new_case()
    open_project(env, project)
    old = load(state_path)
    old_id = old["workspaces"][0]["workspace_id"]
    old["workspaces"][0]["tokens"]["local_ai_project"] = "another-project-after-server-restart"
    state_path.write_text(json.dumps(old))
    open_project(env, project)
    refreshed = load(state_path)
    check(len(refreshed["workspaces"]) == 2, "Stale registry adopted an unrelated reused workspace id")
    check(refreshed["workspaces"][0]["tokens"]["local_ai_project"] == "another-project-after-server-restart", "Stale registry overwrote unrelated workspace metadata")
    check(not refreshed["runs"], "Stale registry sent commands into unrelated panes")
    passed("Herdr validates workspace ownership before reusing registry ids")

    case, project, state_path, env = new_case()
    open_project(env, project)
    restored = load(state_path)
    restored_ids = {item["pane_id"] for item in restored["panes"]}
    # Native v0.9.0 persists labels/ids/cwd but intentionally resets metadata tokens.
    for work in restored["workspaces"]:
        work["tokens"] = {}
    state_path.write_text(json.dumps(restored))
    before_mutations = mutations(restored)
    before_registry = (Path(env["HERDR_CONFIG_DIR"]) / "workspaces.json").read_bytes()
    listed = json.loads(invoke(env, "list").stdout)
    status = json.loads(invoke(env, "status", project).stdout)
    check(len(listed["workspaces"]) == len(status["workspaces"]) == 1,
          "Read-only inspection hid a restored workspace before reopening")
    check(mutations(load(state_path)) == before_mutations,
          "Read-only restored workspace discovery mutated Herdr")
    check((Path(env["HERDR_CONFIG_DIR"]) / "workspaces.json").read_bytes() == before_registry,
          "Read-only restored workspace discovery changed the registry")
    open_project(env, project)
    resumed = load(state_path)
    check(len(resumed["workspaces"]) == 1, "Reopening a restarted server duplicated its restored workspace")
    check({item["pane_id"] for item in resumed["panes"]} == restored_ids, "Restart recovery replaced restored panes")
    check(not resumed["runs"], "Restart recovery silently relaunched commands")
    passed("Herdr recovers native restart metadata loss without duplicating restored panes")

    case, project, state_path, env = new_case()
    open_project(env, project, profile="golf")
    open_project(env, project, profile="ops")
    check(len(load(state_path)["workspaces"]) == 2, "Distinct project profiles should remain independently reusable")
    passed("Herdr golf and operations profiles create separate reusable workspaces")

    case, project, state_path, env = new_case()
    open_project(env, project)
    prompt = case / "review prompt.txt"
    prompt.write_text("Review the collision code.\nPreserve 'quotes' and $(literal text).\n")
    invoke(env, "delegate", "lead", project, "--tier", "selected", "--prompt-file", prompt, "--timeout", "3")
    delegated = load(state_path)
    check(delegated["prompts"][-1]["text"] == prompt.read_text(), "Delegation changed prompt-file contents")
    prompts = [call for call in delegated["calls"] if call[:2] == ["agent", "prompt"]]
    check("--wait" in prompts[-1] and "--timeout" in prompts[-1], "Delegation did not request a bounded lifecycle wait")
    check(prompts[-1][prompts[-1].index("--timeout") + 1] == "3000", "Delegation did not convert seconds to Herdr milliseconds")
    passed("Herdr delegation preserves prompt text and bounds native lifecycle waits")
    for outcome in ("unknown", "blocked"):
        update(state_path, prompt_status=outcome)
        invoke(env, "delegate", "lead", project, "--tier", "selected", "--prompt-file", prompt, "--timeout", "3", success=False)
    update(state_path, prompt_status="idle", prompt_error="timeout")
    invoke(env, "delegate", "lead", project, "--tier", "selected", "--prompt-file", prompt, "--timeout", "3", success=False)
    passed("Herdr unknown, blocked, and timed-out delegation never reports completion")
    update(state_path, agent_status="blocked", prompt_error="", prompt_status="idle")
    before = len(load(state_path)["prompts"])
    invoke(env, "delegate", "lead", project, "--tier", "selected", "--prompt-file", prompt, "--timeout", "1", success=False)
    check(len(load(state_path)["prompts"]) == before, "Blocked approval UI received a new prompt")
    passed("Herdr does not type a new delegation into a blocked approval dialog")

    case, project, state_path, env = new_case()
    registry = Path(env["HERDR_CONFIG_DIR"]) / "workspaces.json"
    registry.write_text("user-authored invalid registry")
    open_project(env, project, success=False)
    check(registry.read_text() == "user-authored invalid registry", "Invalid registry was overwritten")
    check(not mutations(load(state_path)), "Invalid registry caused server mutation")
    passed("Herdr refuses a malformed registry without replacing it")

    case, project, state_path, env = new_case()
    config = Path(env["HERDR_CONFIG_DIR"])
    shutil.rmtree(config)
    outside = case / "user-owned"
    outside.mkdir()
    sentinel = outside / "preserve"
    sentinel.write_text("user configuration")
    config.symlink_to(outside, target_is_directory=True)
    open_project(env, project, success=False)
    check(sentinel.read_text() == "user configuration", "Symlink target was modified")
    check(not mutations(load(state_path)), "Symlinked state path caused server mutation")
    passed("Herdr preserves symlinked user state boundaries")
finally:
    for path in temp.glob("*/mock.json"):
        try:
            pid = load(path).get("server_pid")
            if pid:
                os.kill(pid, signal.SIGTERM)
        except (FileNotFoundError, ProcessLookupError, ValueError):
            pass
PY
