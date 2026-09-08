#!/usr/bin/env python3
"""Offline Herdr 0.9.0 CLI fixture with durable observable server state.

Tests own HERDR_MOCK_STATE. Controls are running, version, busy_panes,
agent_status, fail_command (space-separated command prefix), fail_remaining,
and wait_error. Every CLI call is recorded; submitted commands live in runs.
"""

import fcntl
import json
import os
from pathlib import Path
import signal
import shlex
import sys
import time


state_path = Path(os.environ["HERDR_MOCK_STATE"])
state_path.parent.mkdir(parents=True, exist_ok=True)
lock = open(str(state_path) + ".lock", "a")
fcntl.flock(lock, fcntl.LOCK_EX)
state = json.loads(state_path.read_text()) if state_path.exists() else {}
for key, value in {"running": True, "version": "0.9.0", "calls": [], "runs": [],
                   "workspaces": [], "tabs": [], "panes": [], "next_workspace": 1,
                   "agent_status": "idle"}.items():
    state.setdefault(key, value)
args = sys.argv[1:]
while "--session" in args:
    index = args.index("--session")
    state["session"] = args[index + 1]
    del args[index:index + 2]
state["calls"].append(args)


def save():
    temporary = state_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(state))
    os.replace(temporary, state_path)


def done(result=None, error=None, raw=None):
    save()
    if error:
        print(json.dumps({"id": "fixture", "error": {"code": error, "message": error}}), file=sys.stderr)
        raise SystemExit(1)
    if raw is not None:
        print(raw)
    elif result is not None:
        print(json.dumps({"id": "fixture", "result": result}))
    raise SystemExit(0)


def option(name, default=None):
    return args[args.index(name) + 1] if name in args else default


def workspace(identifier):
    return next((item for item in state["workspaces"] if item["workspace_id"] == identifier), None)


def pane(identifier):
    return next((item for item in state["panes"] if item["pane_id"] == identifier or item.get("name") == identifier), None)


def new_pane(wid, tid, cwd):
    number = 1 + max([int(item["pane_id"].split(":p")[1]) for item in state["panes"] if item["workspace_id"] == wid] or [0])
    result = {"pane_id": f"{wid}:p{number}", "terminal_id": f"term_{wid}_{number}",
              "workspace_id": wid, "tab_id": tid, "cwd": cwd, "foreground_cwd": cwd,
              "focused": False, "agent_status": "unknown", "revision": 0}
    state["panes"].append(result)
    return result


def new_tab(wid, cwd, label):
    number = 1 + len([item for item in state["tabs"] if item["workspace_id"] == wid])
    result = {"tab_id": f"{wid}:t{number}", "workspace_id": wid, "number": number,
              "label": label or str(number), "focused": False, "pane_count": 1,
              "agent_status": "unknown"}
    state["tabs"].append(result)
    return result, new_pane(wid, result["tab_id"], cwd)


def agent(target):
    found = pane(target)
    if not found or not found.get("agent"):
        done(error="agent_not_running")
    return dict(found, agent_status=state.get("agent_status", "idle"), name=found.get("name"),
                interactive_ready=state.get("agent_status", "idle") in {"idle", "done"})


prefix = state.get("fail_command", "").split()
if prefix and args[:len(prefix)] == prefix and state.get("fail_remaining", 0) > 0:
    state["fail_remaining"] -= 1
    done(error=state.get("fail_error", "fixture_injected_failure"))

if args in (["--version"], ["-V"]):
    done(raw="herdr " + state["version"])
if args[:2] == ["status", "server"]:
    save()
    print(json.dumps({"status": "running" if state["running"] else "not_running",
                      "running": state["running"], "version": state["version"] if state["running"] else None,
                      "protocol": 22, "compatible": True, "session": state.get("session", "local-ai"),
                      "socket": str(state_path.parent / "herdr.sock")}))
    raise SystemExit(0)
if args == ["server"]:
    state["running"] = True
    state["server_pid"] = os.getpid()
    save()
    fcntl.flock(lock, fcntl.LOCK_UN)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    while True:
        time.sleep(1)
if args == ["server", "stop"]:
    state["running"] = False
    done()
if not args:
    if state.get("attach_check_lock"):
        with open(state["attach_check_lock"], "a") as registry_lock:
            try:
                fcntl.flock(registry_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                done(error="fixture_attachment_retained_registry_lock")
    state["attachments"] = state.get("attachments", 0) + 1
    done()
if not state["running"]:
    done(error="server_not_running")

if args[:2] == ["workspace", "list"]:
    done({"type": "workspace_list", "workspaces": state["workspaces"]})
if args[:2] == ["workspace", "create"]:
    wid = "w" + str(state["next_workspace"])
    state["next_workspace"] += 1
    tab, root = new_tab(wid, option("--cwd"), None)
    work = {"workspace_id": wid, "number": len(state["workspaces"]) + 1,
            "label": option("--label", wid), "focused": False, "pane_count": 1,
            "tab_count": 1, "active_tab_id": tab["tab_id"], "tokens": {}, "agent_status": "unknown"}
    state["workspaces"].append(work)
    done({"type": "workspace_created", "workspace": work, "tab": tab, "root_pane": root})
if args[:2] == ["workspace", "report-metadata"]:
    work = workspace(args[2])
    if not work:
        done(error="workspace_not_found")
    for index, item in enumerate(args):
        if item == "--token":
            key, value = args[index + 1].split("=", 1)
            work["tokens"][key] = value
    done()
if args[:2] == ["workspace", "focus"]:
    if not workspace(args[2]):
        done(error="workspace_not_found")
    done({"type": "ok"})
if args[:2] == ["workspace", "get"]:
    found = workspace(args[2])
    done({"workspace": found}) if found else done(error="workspace_not_found")
if args[:2] == ["tab", "create"]:
    tab, root = new_tab(option("--workspace"), option("--cwd"), option("--label"))
    done({"type": "tab_created", "tab": tab, "root_pane": root})
if args[:2] == ["tab", "rename"]:
    for item in state["tabs"]:
        if item["tab_id"] == args[2]:
            item["label"] = args[3]
    done({"type": "ok"})
if args[:2] == ["tab", "list"]:
    done({"type": "tab_list", "tabs": [item for item in state["tabs"] if not option("--workspace") or item["workspace_id"] == option("--workspace")]})
if args[:2] == ["pane", "split"]:
    source = pane(option("--pane", args[2]))
    if not source:
        done(error="pane_not_found")
    root = new_pane(source["workspace_id"], source["tab_id"], option("--cwd", source["cwd"]))
    done({"type": "pane_info", "pane": root})
if args[:2] == ["pane", "list"]:
    done({"type": "pane_list", "panes": [item for item in state["panes"] if not option("--workspace") or item["workspace_id"] == option("--workspace")]})
if args and args[0] == "pane" and len(args) >= 3:
    target = option("--pane", args[2])
    found = pane(target)
    if not found:
        done(error="pane_not_found")
    action = args[1]
    if action == "get":
        done({"type": "pane_info", "pane": found})
    if action == "rename":
        found["label"] = args[3]
        done({"type": "ok"})
    if action == "report-metadata":
        for index, item in enumerate(args):
            if item == "--token":
                key, value = args[index + 1].split("=", 1)
                found.setdefault("tokens", {})[key] = value
        done()
    if action == "process-info":
        busy = target in state.get("busy_panes", []) or bool(found.get("agent"))
        executable = "worker" if busy else state.get("shell_name", "bash")
        process = {"pid": 4343 if busy else 4242, "name": executable,
                   "argv": ["/bin/" + executable], "cwd": found.get("foreground_cwd", found["cwd"])}
        done({"type": "pane_process_info", "process_info": {"pane_id": target,
              "shell_pid": 4242, "foreground_process_group_id": process["pid"],
              "foreground_processes": [process]}})
    if action == "run":
        state["runs"].append({"pane_id": target, "command": args[3]})
        words = shlex.split(args[3])
        if words[:2] == ["cd", "--"] and len(words) > 3 and words[3] == "&&":
            words = words[4:]
        executable = Path(words[0]).name if words else ""
        if executable == "local-ai-agent" or executable.startswith("omp-") or executable == "pi":
            found["agent"] = "pi" if executable == "pi" or "pi" in words[1:] else "omp"
            found["agent_status"] = state.get("agent_status", "idle")
        done()
    if action == "read":
        done(raw=state.get("read_output", "fixture pane output"))
if args and args[0] == "agent" and len(args) >= 3:
    current = agent(args[2])
    action = args[1]
    if action == "get":
        done({"type": "agent_info", "agent": current})
    if action == "rename":
        pane(args[2])["name"] = args[3]
        done({"type": "ok"})
    if action in {"wait", "prompt"}:
        if action == "wait" and state.get("wait_error"):
            done(error=state["wait_error"])
        if action == "prompt":
            if state.get("agent_status") == "blocked":
                done(error="agent_blocked")
            state.setdefault("prompts", []).append({"pane_id": current["pane_id"], "text": args[3]})
            if state.get("prompt_error"):
                done(error=state["prompt_error"])
            current["agent_status"] = state.get("prompt_status", current["agent_status"])
        done({"type": "agent_prompted" if action == "prompt" else "agent_info", "agent": current})
    if action == "read":
        done(raw=state.get("read_output", "fixture pane output"))
done(error="fixture_unsupported_command:" + " ".join(args))
