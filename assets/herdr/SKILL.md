---
name: local-ai-herdr
description: Coordinate project work in this setup's Herdr role panes using local model launchers, explicit build commands, and synchronous specialist delegation. Use when working inside a Local AI Herdr workspace or when the user asks to organize work there.
---

<!-- Managed by local-ai-setup: Herdr skill -->

# Local AI Herdr coordination

Use `local-ai-workspace` for this setup's project/role operations and
`local-ai-herdr` for scoped raw Herdr inspection. Both select the private
`local-ai` session. Avoid bare `herdr`, `omp`, or `pi` when launching this
stack: the managed agent wrappers select its pinned runtime and load current
local API credentials.

## Find the existing work

Run `local-ai-workspace status "$PWD"` or `list` before creating panes.
Workspace identity is the canonical project path. `open "$PWD" --no-attach`
reuses an existing workspace; `--no-agent` suppresses Lead on first creation.
Do not open duplicate projects or restart a live agent merely to attach.

Profiles have separate layouts for the same project. Pass `--profile golf`
(or `coding`/`ops`) to role commands when the path has more than one profile.
`--no-agent` suppresses the initial journal/status commands too.

Coding roles are `lead`, `shell`, `tests`, `build`, `logs`, and `status`.
The golf profile adds `physics`, `course`, `rendering`, and `audio`; these are
available roles, not instructions to start four agents. Operations has
`logs`, `status`, and `shell` without a lead agent.

## Keep one coherent line of work

This Framework Desktop serves one resident model and one inference request
at a time. Prefer Lead for the active task and a bounded specialist when it
adds useful expertise. Independent interactive agents can queue requests.
All roles in a project share its checkout: give concurrent editors distinct
files, or use separate existing worktree paths when isolation is needed.

For a specialist, write a prompt file containing the task, relevant context,
edit boundaries, and expected deliverable. Then run, for example:

```bash
local-ai-workspace delegate physics "$PWD" \
  --tier coder --prompt-file /absolute/path/review.txt --timeout 1800
local-ai-workspace read physics "$PWD" --lines 120
```

Delegation waits synchronously and permits one helper-launched delegated task
across this setup; concurrent requests fail instead of queueing. Wait for its result instead of starting more model work
in the lead. Other API clients remain independent; this is not a global
semaphore over all agents. Choose `selected`, `everyday`, `coder`, `senior`,
or `pi` only when the corresponding configured agent/tier is available.

If the worker blocks or times out, inspect its pane and resolve the specific
state before retrying. Do not submit the prompt again merely because a wait
ended. Report what remains unfinished. Treat worker output as a result to
review; an idle agent state does not prove correctness.

## Run the project's actual commands

Read the repository's own guidance and use its established commands:

```bash
local-ai-workspace run tests "$PWD" -- npm test
local-ai-workspace read tests "$PWD" --lines 80
```

The npm command is an example, not a default. Supply executable arguments
after `--`; shell operators require an explicitly selected shell. Inspect an
occupied role before sending another command. Keep edits and external actions
within the user's requested scope; pane access adds no permission.

Detach preserves running terminals. After a reboot or Herdr restart, layout
restoration does not resume agents or builds. Restart requested agents through
`local-ai-workspace agent ROLE PROJECT --tier TIER`, and restart project
commands explicitly. Keep API keys out of prompts, project files, and pane
command strings.
