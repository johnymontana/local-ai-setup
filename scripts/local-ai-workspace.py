#!/usr/bin/env python3
"""Project workspaces for the pinned Herdr CLI. Uses only Python's stdlib.

Herdr owns terminals and session persistence; this small registry owns role
assignment and recovery of interrupted layout creation. It never runs project
scripts implicitly, starts an inference server, or closes existing terminals.
"""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
PROFILES = {
    "coding": [("Code", "lead", "shell"), ("Workbench", "tests", "build"),
               ("Observe", "logs", "status")],
    "golf": [("Code", "lead", "shell"), ("Workbench", "tests", "build"),
             ("Observe", "logs", "status"), ("Simulation", "physics", "course"),
             ("Presentation", "rendering", "audio")],
    "ops": [("Observe", "logs", "status"), ("Shell", "shell", None)],
}
TIERS = ("selected", "everyday", "coder", "senior", "pi")
ROLES = sorted({role for groups in PROFILES.values() for group in groups
                for role in group[1:] if role})


class WorkspaceError(Exception):
    pass


def clean_path(value):
    if any(ord(char) < 32 or ord(char) == 127 for char in str(value)):
        raise WorkspaceError("Paths may not contain control characters")
    return Path(value).expanduser().absolute()


def regular_path(path, directory=False):
    """Reject symlinks and nonregular state paths before any write or spawn."""
    path = clean_path(path)
    for parent in [path, *path.parents]:
        if parent.is_symlink():
            raise WorkspaceError(f"Symlinked configuration/state path preserved: {parent}")
        if parent.exists() and parent != path and not parent.is_dir():
            raise WorkspaceError(f"Not a configuration directory: {parent}")
    if path.exists() and not (path.is_dir() if directory else path.is_file()):
        raise WorkspaceError(f"Non-regular configuration/state path preserved: {path}")
    return path


def digest(value):
    return hashlib.sha256(str(value).encode()).hexdigest()


class Workspaces:
    def __init__(self):
        home = Path.home()
        self.config = clean_path(os.environ.get("LOCAL_AI_CONFIG_DIR", home / ".config/local-ai"))
        self.directory = regular_path(os.environ.get("HERDR_CONFIG_DIR", self.config / "herdr"), True)
        self.state_path = regular_path(self.directory / "workspaces.json")
        self.bin = clean_path(os.environ.get("LOCAL_BIN_DIR", home / ".local/bin"))
        self.wrapper = self.bin / "local-ai-herdr"
        saved = {}
        setup = regular_path(os.environ.get("SETUP_ENV", self.config / "setup.env"))
        if setup.exists():
            for line in setup.read_text().splitlines():
                key, separator, value = line.partition("=")
                if separator:
                    saved[key] = value
        self.version = os.environ.get("HERDR_VERSION", saved.get("HERDR_VERSION", "0.9.0"))
        self.owner = digest(self.directory)
        self.state = {"schema_version": 1, "projects": {}}
        self.env = dict(os.environ)
        for key in ("LLAMA_API_KEY", "LLAMA_BASE_URL", "LLAMA_CPP_BASE_URL"):
            self.env.pop(key, None)
        self.env.update(LOCAL_AI_CONFIG_DIR=str(self.config),
                        HERDR_CONFIG_DIR=str(self.directory), HERDR_SESSION="local-ai")

    def call(self, *args, timeout=15, raw=False):
        if not self.wrapper.is_file() or not os.access(self.wrapper, os.X_OK):
            raise WorkspaceError("Herdr is not installed. Run local-ai herdr first.")
        try:
            result = subprocess.run([str(self.wrapper), *map(str, args)], env=self.env,
                                    text=True, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            raise WorkspaceError(f"Herdr {args[0]} timed out. Inspect the pane before retrying; input may already have been sent.") from error
        if result.returncode:
            # Never include the command argv here: agent prompts can be private.
            detail = (result.stderr or result.stdout).strip()
            raise WorkspaceError(f"Herdr {' '.join(map(str, args[:2]))} failed: {detail}")
        if raw:
            return result.stdout
        if not result.stdout.strip() and tuple(args[:2]) in {
                ("workspace", "report-metadata"), ("pane", "report-metadata"), ("pane", "run")}:
            return {}
        try:
            value = json.loads(result.stdout)
        except ValueError as error:
            raise WorkspaceError("Herdr returned invalid JSON; check the pinned runtime and server version") from error
        if value.get("error"):
            raise WorkspaceError(f"Herdr error: {value['error']}")
        return value.get("result", value)

    def server(self, start=False):
        if not self.wrapper.exists() and not start:
            return {"running": False, "status": "not_installed"}
        status = self.call("status", "server", "--json")
        if status.get("running"):
            if str(status.get("version", "")).lstrip("v") != self.version or status.get("compatible") is False:
                raise WorkspaceError(f"Running Herdr {status.get('version')} differs from pinned {self.version}. Finish active work, then run local-ai-herdr server stop and reopen the workspace.")
            return status
        if not start:
            return status
        config = regular_path(self.directory / "config.toml")
        if not config.exists():
            raise WorkspaceError("Herdr configuration is missing. Run local-ai herdr-config.")
        log = regular_path(self.directory / "server.log")
        fd = os.open(log, os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "a") as output:
            process = subprocess.Popen([str(self.wrapper), "server"], env=self.env,
                                       stdin=subprocess.DEVNULL, stdout=output, stderr=output,
                                       start_new_session=True)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            status = self.server()
            if status.get("running"):
                return status
            if process.poll() is not None:
                raise WorkspaceError(f"Herdr server exited. Inspect {log}")
            time.sleep(0.1)
        raise WorkspaceError(f"Herdr server did not become ready. Inspect {log} before retrying.")

    @contextmanager
    def lock(self, name="layout", blocking=True):
        regular_path(self.directory, True)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        path = regular_path(self.directory / f"{name}.lock")
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
            except BlockingIOError as error:
                raise WorkspaceError("Another local-ai delegation is active. Wait for it before delegating again.") from error
            self.load()
            yield
        finally:
            os.close(fd)

    def load(self):
        regular_path(self.state_path)
        if self.state_path.exists():
            try:
                self.state = json.loads(self.state_path.read_text())
                if self.state.get("schema_version") != 1 or not isinstance(self.state["projects"], dict):
                    raise ValueError("Unsupported workspace registry")
            except (ValueError, KeyError, TypeError) as error:
                raise WorkspaceError(f"Invalid workspace registry preserved: {self.state_path}") from error

    def save(self):
        regular_path(self.state_path)
        fd, name = tempfile.mkstemp(prefix=".workspaces-", dir=self.directory)
        try:
            with os.fdopen(fd, "w") as output:
                json.dump(self.state, output, indent=2)
                output.write("\n")
                output.flush()
                os.fsync(output.fileno())
            os.replace(name, self.state_path)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def workspace_list(self):
        return self.call("workspace", "list")["workspaces"]

    def label(self, project, profile):
        key = f"{digest(project)}:{profile}"
        return f"{project.name[:32]} · {profile} · {digest(key + self.owner)[:10]}"

    def match(self, work, project, profile):
        expected = {"local_ai_owner": self.owner, "local_ai_project": digest(project),
                    "local_ai_profile": profile}
        tokens = work.get("tokens", {})
        if all(tokens.get(k) == v for k, v in expected.items()):
            return work
        if work.get("label") != self.label(project, profile) or any(tokens.get(k, v) != v for k, v in expected.items()):
            return None
        panes = self.call("pane", "list", "--workspace", work["workspace_id"])["panes"]
        if any(pane.get("cwd") and Path(pane["cwd"]).resolve() == project for pane in panes):
            # These are recovered identity fields in this response only; status
            # and attach never rewrite native metadata or the registry.
            return dict(work, tokens={**tokens, **expected}, restored_layout=True)
        return None

    def find(self, project, profile=None):
        matches = []
        for work in self.workspace_list():
            for candidate in ([profile] if profile else PROFILES):
                found = self.match(work, project, candidate)
                if found:
                    matches.append(found)
        if not matches:
            return None
        if len(matches) != 1:
            raise WorkspaceError("Multiple workspaces match; select --profile coding, golf, or ops (or inspect duplicate workspace metadata).")
        return matches[0]

    def ensure_layout(self, project, profile):
        key = f"{digest(project)}:{profile}"
        label = self.label(project, profile)
        record = self.state["projects"].get(key)
        work = self.find(project, profile)
        first_role = PROFILES[profile][0][1]
        if not work:
            created = self.call("workspace", "create", "--cwd", project,
                                "--label", label, "--no-focus")
            work = created["workspace"]
            record = {"project": str(project), "profile": profile,
                      "workspace_id": work["workspace_id"],
                      "roles": {first_role: created["root_pane"]["pane_id"]},
                      "initialized": [], "pending_roles": [first_role]}
            self.state["projects"][key] = record
            self.save()
        elif not record:
            record = {"project": str(project), "profile": profile,
                      "workspace_id": work["workspace_id"], "roles": {},
                      "initialized": ["lead", "logs", "status"]}
            panes = self.call("pane", "list", "--workspace", work["workspace_id"])["panes"]
            if len(panes) == 1 and not panes[0].get("tokens", {}).get("local_ai_role"):
                record["roles"][first_role] = panes[0]["pane_id"]
                record["pending_roles"] = [first_role]
            self.state["projects"][key] = record
        record["workspace_id"] = work["workspace_id"]
        wid = work["workspace_id"]
        self.call("workspace", "report-metadata", wid, "--source", "local-ai",
                  "--token", f"local_ai_owner={self.owner}",
                  "--token", f"local_ai_project={digest(project)}",
                  "--token", f"local_ai_profile={profile}")
        panes = self.call("pane", "list", "--workspace", wid)["panes"]
        live_by_id = {pane["pane_id"]: pane for pane in panes}
        pending = record.setdefault("pending_roles", [])
        record["roles"] = {role: pid for role, pid in record["roles"].items()
                           if pid in live_by_id and
                           live_by_id[pid].get("tokens", {}).get("local_ai_role", role) == role and
                           (live_by_id[pid].get("tokens", {}).get("local_ai_role") == role
                            or live_by_id[pid].get("label") == role.title()
                            or role in pending)}
        for pane in panes:
            role = pane.get("tokens", {}).get("local_ai_role")
            if not role:
                role = next((candidate for candidate in ROLES
                             if pane.get("label") == candidate.title()), None)
            if role in ROLES and role not in record["roles"] and pane.get("cwd") \
                    and Path(pane["cwd"]).resolve() == project:
                record["roles"][role] = pane["pane_id"]
        for title, left, right in PROFILES[profile]:
            if left not in record["roles"]:
                created = self.call("tab", "create", "--workspace", wid, "--cwd", project,
                                    "--label", title, "--no-focus")
                record["roles"][left] = created["root_pane"]["pane_id"]
                pending.append(left)
                self.save()
            left_id = record["roles"][left]
            pane = self.call("pane", "get", left_id)["pane"]
            self.call("tab", "rename", pane["tab_id"], title)
            for role in (left, right):
                if role is None:
                    continue
                if role not in record["roles"]:
                    created = self.call("pane", "split", left_id, "--direction", "right",
                                        "--ratio", "0.5", "--cwd", project, "--no-focus")
                    record["roles"][role] = created["pane"]["pane_id"]
                    pending.append(role)
                    self.save()
                pid = record["roles"][role]
                self.call("pane", "rename", pid, role.title())
                self.call("pane", "report-metadata", pid, "--source", "local-ai",
                          "--token", f"local_ai_role={role}")
                if role in pending:
                    pending.remove(role)
        self.save()
        return work, record

    def locate(self, project, profile, role=None):
        if not self.server().get("running"):
            raise WorkspaceError("Herdr is not running. Open the project workspace first.")
        work = self.find(project, profile)
        if not work:
            raise WorkspaceError("No managed workspace for this project. Run local-ai workspace open first.")
        if role is None:
            return work
        panes = self.call("pane", "list", "--workspace", work["workspace_id"])["panes"]
        matches = [pane for pane in panes if pane.get("tokens", {}).get("local_ai_role") == role
                   or (work.get("restored_layout") and not pane.get("tokens", {}).get("local_ai_role")
                       and pane.get("label") == role.title() and pane.get("cwd")
                       and Path(pane["cwd"]).resolve() == project)]
        if len(matches) != 1:
            raise WorkspaceError(f"Role {role} is missing or ambiguous; reopen the workspace to repair its layout.")
        return dict(matches[0], _project=str(project))

    def require_shell(self, pid):
        info = self.call("pane", "process-info", "--pane", pid)["process_info"]
        shell_pid = info.get("shell_pid")
        processes = info.get("foreground_processes", [])
        shells = {"bash", "zsh", "sh", "dash", "ksh"}
        if not shell_pid or info.get("foreground_process_group_id") != shell_pid or not processes \
                or any(process.get("pid") != shell_pid or
                       Path(process.get("name", "")).name.lstrip("-") not in shells
                       for process in processes):
            raise WorkspaceError(f"Pane {pid} is busy or its shell readiness is unknown. Inspect it before sending a command.")

    def run(self, pane, argv):
        if not argv or any(any(ord(char) < 32 or ord(char) == 127 for char in arg) for arg in argv):
            raise WorkspaceError("Provide a command after --; terminal commands may not contain control characters")
        self.require_shell(pane["pane_id"])
        command = shlex.join(argv)
        if pane.get("_project"):
            command = "cd -- " + shlex.quote(pane["_project"]) + " && " + command
        self.call("pane", "run", pane["pane_id"], command)

    def agent_command(self, tier):
        name = "local-ai-agent" if tier == "selected" else "local-ai-pi" if tier == "pi" else f"omp-{tier}"
        path = self.bin / name
        if not path.is_file() or not os.access(path, os.X_OK):
            hint = "local-ai agent" if tier == "selected" else "local-ai pi && local-ai herdr-config" if tier == "pi" else f"local-ai model {tier} && local-ai routing"
            raise WorkspaceError(f"Missing {name}. Run {hint} first.")
        return [str(path)]

    def start_agent(self, pane, tier):
        pid = pane["pane_id"]
        current = self.call("pane", "get", pid)["pane"]
        current["_project"] = pane.get("_project")
        active = current.get("agent") or current.get("display_agent")
        if active:
            previous = current.get("tokens", {}).get("local_ai_tier")
            if previous != tier:
                raise WorkspaceError(f"Pane {pid} already has an agent ({previous or 'unmanaged tier'}). Exit it before choosing {tier}.")
            return
        self.run(current, self.agent_command(tier))
        self.call("pane", "report-metadata", pid, "--source", "local-ai",
                  "--token", f"local_ai_tier={tier}")

    def ready_agent(self, pid, timeout):
        deadline = time.monotonic() + min(timeout, 30)
        last = "unknown"
        while time.monotonic() < deadline:
            current = self.call("pane", "get", pid)["pane"]
            if current.get("agent") or current.get("display_agent"):
                agent = self.call("agent", "get", pid)["agent"]
                last = agent.get("agent_status", "unknown")
                if last in ("idle", "done"):
                    return agent
                # Do not join a running turn or approve a blocked request.
                if last in ("working", "blocked", "error", "stalled"):
                    break
            time.sleep(0.2)
        raise WorkspaceError(f"Agent {pid} is {last}, not ready for a new prompt. Inspect its pane and lifecycle hook before retrying.")

    def delegate(self, pane, tier, prompt, timeout):
        pid = pane["pane_id"]
        if os.environ.get("HERDR_PANE_ID") == pid:
            raise WorkspaceError("An agent cannot delegate to its own pane; choose a supporting role")
        # This serializes helper delegations across projects. It does not alter
        # llama.cpp's one-slot limit or promise to serialize manually run agents.
        with self.lock("delegate", blocking=False):
            with self.lock():
                self.start_agent(pane, tier)
            self.ready_agent(pid, timeout)
            self.call("agent", "rename", pid, "local-" + digest(pid + self.owner)[:12])
            try:
                result = self.call("agent", "prompt", pid, prompt, "--wait",
                                   "--timeout", int(timeout * 1000), timeout=timeout + 5)
            except WorkspaceError as error:
                raise WorkspaceError(f"{error}\nPrompt submission may have occurred. Read the pane before retrying; no automatic retry was attempted.") from error
            agent = result.get("agent", {})
            state = agent.get("agent_status", "unknown")
            if state not in ("idle", "done"):
                raise WorkspaceError(f"Delegated agent returned {state}; inspect its output and approvals before continuing.")
            print(f"Agent {pid} returned {state}. Review its changes and tests; this is a lifecycle result, not proof the task passed.")
            print(self.call("pane", "read", pid, "--source", "recent-unwrapped", "--lines", 80, raw=True), end="")

    def attach(self, work):
        self.call("workspace", "focus", work["workspace_id"])
        # No lifecycle/registry lock survives exec; detaching leaves Herdr alive.
        os.execve(self.wrapper, [str(self.wrapper)], self.env)


def arguments(argv):
    commands = {"open", "list", "status", "attach", "run", "agent", "delegate", "read"}
    if not argv:
        argv = ["open"]
    elif argv[0] not in commands and not argv[0].startswith("-"):
        argv = ["open", *argv]
    parser = argparse.ArgumentParser(description="Persistent project terminals around the local AI service.")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in commands:
        child = sub.add_parser(name)
        if name in ("run", "agent", "delegate", "read"):
            child.add_argument("role", choices=ROLES)
        if name != "list":
            child.add_argument("project", nargs="?", default=os.getcwd())
            child.add_argument("--profile", choices=PROFILES, default="coding" if name == "open" else None)
        if name == "open":
            child.add_argument("--no-attach", action="store_true")
            child.add_argument("--no-agent", action="store_true", help="Prepare shells only; do not initialize agent/log/status commands")
        if name in ("agent", "delegate"):
            child.add_argument("--tier", choices=TIERS, default="selected")
            child.add_argument("--timeout", type=int, default=1800 if name == "delegate" else 30)
        if name == "delegate":
            child.add_argument("--prompt-file", required=True)
        if name == "read":
            child.add_argument("--lines", type=int, default=80)
    # Keep flags intended for the project command out of argparse entirely.
    command_argv = []
    if argv[0] == "run" and "--" in argv:
        split = argv.index("--")
        argv, command_argv = argv[:split], argv[split + 1:]
    args = parser.parse_args(argv)
    args.argv = command_argv
    if args.command == "run" and not command_argv:
        parser.error("run requires -- followed by a command and its arguments")
    if hasattr(args, "timeout") and not 1 <= args.timeout <= 86400:
        parser.error("--timeout must be 1-86400 seconds")
    if hasattr(args, "lines") and not 1 <= args.lines <= 10000:
        parser.error("--lines must be 1-10000")
    return args


def main(argv):
    args = arguments(argv)
    project = None
    if hasattr(args, "project"):
        project = clean_path(args.project).resolve(strict=True)
        if not project.is_dir():
            raise WorkspaceError(f"Project is not a directory: {project}")
    prompt = None
    if args.command == "delegate":
        path = regular_path(clean_path(args.prompt_file))
        if not path.exists() or path.stat().st_size > 131072:
            raise WorkspaceError("Prompt file must be a regular UTF-8 file of at most 128 KiB")
        prompt = path.read_text()
        if not prompt.strip() or any((ord(char) < 32 and char not in "\n\r\t") or ord(char) == 127 for char in prompt):
            raise WorkspaceError("Prompt file must contain nonempty text without terminal control characters")
    api = Workspaces()
    if args.command in ("list", "status"):
        server = api.server()
        if not server.get("running"):
            print(json.dumps({"server": server, "workspaces": []}, indent=2))
            return
        live = api.workspace_list()
        workspaces = {work["workspace_id"]: work for work in live
                      if work.get("tokens", {}).get("local_ai_owner") == api.owner}
        api.load()
        identities = [(project, profile) for profile in PROFILES] if project else [
            (Path(record["project"]), record["profile"]) for record in api.state["projects"].values()]
        for path, profile in identities:
            for work in live:
                found = api.match(work, path, profile)
                if found:
                    workspaces[work["workspace_id"]] = found
        workspaces = list(workspaces.values())
        if project:
            workspaces = [work for work in workspaces if work["tokens"].get("local_ai_project") == digest(project)
                          and (args.profile is None or work["tokens"].get("local_ai_profile") == args.profile)]
        for work in workspaces:
            work["panes"] = api.call("pane", "list", "--workspace", work["workspace_id"])["panes"]
        print(json.dumps({"server": server, "workspaces": workspaces}, indent=2))
    elif args.command == "open":
        with api.lock():
            api.server(start=True)
            work, record = api.ensure_layout(project, args.profile)
            if not args.no_agent:
                commands = {"logs": ["journalctl", "--user", "-u", "llama-server.service", "-f"],
                            "status": ["bash", str(ROOT / "local-ai"), "status"]}
                if "lead" in record["roles"]:
                    commands = {"lead": api.agent_command("selected"), **commands}
                for role, command in commands.items():
                    if role in record["initialized"]:
                        continue
                    pid = record["roles"][role]
                    # Claim before submission: interruption never replays input.
                    api.require_shell(pid)
                    record["initialized"].append(role)
                    api.save()
                    if role == "lead":
                        api.start_agent({"pane_id": pid, "_project": str(project)}, "selected")
                    else:
                        api.run({"pane_id": pid, "_project": str(project)}, command)
        if args.no_attach:
            print(f"Workspace {work['workspace_id']} ready: {project} ({args.profile})")
        else:
            api.attach(work)
    elif args.command == "attach":
        api.attach(api.locate(project, args.profile))
    else:
        pane = api.locate(project, args.profile, args.role)
        if args.command == "read":
            print(api.call("pane", "read", pane["pane_id"], "--source", "recent-unwrapped",
                           "--lines", args.lines, raw=True), end="")
        elif args.command == "run":
            with api.lock():
                api.run(pane, args.argv)
            print(f"Command submitted to {args.role} ({pane['pane_id']}). Use workspace read to inspect its output.")
        elif args.command == "agent":
            with api.lock():
                api.start_agent(pane, args.tier)
            api.ready_agent(pane["pane_id"], args.timeout)
            print(f"Agent ready in {args.role} ({pane['pane_id']})")
        elif args.command == "delegate":
            api.delegate(pane, args.tier, prompt, args.timeout)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (WorkspaceError, OSError, UnicodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("Interrupted. Inspect the workspace before retrying; its processes may still be running.", file=sys.stderr)
        sys.exit(130)
