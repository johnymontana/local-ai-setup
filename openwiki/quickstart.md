---
type: "Reference"
title: "Quickstart"
openwiki_generated: true
verified:
  - by: openwiki/0.5.0
    at: 2026-09-08T03:08:40.315Z
sources:
  - id: openwiki-source-03ffc32a0ca502ab67c54b25
    resource: repo://install.sh
  - id: openwiki-source-e845b6622635329fca37f1f6
    resource: repo://local-ai
  - id: openwiki-source-597ac7b7d26678e1e9c41f66
    resource: repo://manage.sh
  - id: openwiki-source-3edea8f57ed1eac0835b85f8
    resource: repo://scripts/local-ai-workspace.py
  - id: openwiki-source-450df187d5ad439853de20f8
    resource: repo://setup-qwen38-pi.sh
  - id: openwiki-source-37c158c9536a90efb6244860
    resource: repo://tests/e2e/workflow-test.sh
  - id: openwiki-source-7e7512e407094ae5459c27c3
    resource: repo://tests/integration/command-contract-test.sh
  - id: openwiki-source-069e6674f1853a4ec99c387e
    resource: repo://tests/run.sh
generated: { by: "openwiki/0.5.0", at: "2026-09-08T03:08:40.315Z" }
---


Use this page to choose the **owner and risk boundary** before editing. The scriptable implementation boundary is `./setup-qwen38-pi.sh`; `manage.sh` is its keyboard-first panel. `local-ai` is the installed front door: it opens that panel, follows router logs, routes workspace requests to the workspace helper, and otherwise invokes the engine.

For a fresh Omarchy workstation installation, inspect the checkout and run `./install.sh` as the desktop user. It accepts no operational arguments and executes the engine's `all` baseline. Keep the checkout: installed front doors resolve the repository from their own location.

## Route the change

| Change or investigation | Read first | Then do this |
|---|---|---|
| Entry points, generated files, local router, service, or ownership | [Runtime Stack and Ownership Boundaries](/openwiki/architecture/runtime-stack.md) | Find the state owner before editing a wrapper or generated file. |
| Configuration precedence, lock records, receipts, symlinks, or managed-file takeover | [Configuration, Artifacts, and Managed-File Safety](/openwiki/concepts/configuration-artifacts-and-safety.md) | Preserve the ownership predicate; do not hand-edit protected generated state. |
| Model tiers, desired settings, planning, apply, downloads, removal, or recovery | [Model, Desired-State, and Apply Lifecycle](/openwiki/workflows/model-and-desired-state-lifecycle.md) | Keep acquisition, review, and activation separate. |
| OMP/pi versions, providers, role mapping, launchers, or remote agent sessions | [Coding Agents and Role Routing](/openwiki/integrations/coding-agents-and-role-routing.md) | Check the pinned-agent and generated routing contract before changing an alias. |
| Readiness, API/authentication, smoke, benchmark, performance, or router residency | [Router Health, Runtime State, and Performance](/openwiki/operations/router-health-and-performance.md) | Start with observational status; schedule a live operation only when it proves the required boundary. |
| Packages, reboot gating, kernel/TTM, LAN access, firewall, or SSH policy | [System and LAN Security](/openwiki/operations/system-and-lan-security.md) | Treat it as a privileged host transaction with its own rollback and preconditions. |
| Herdr installation, a persistent project terminal, profile, pane command, recovery, or delegation | [Persistent Herdr Workspaces and Delegation](/openwiki/workflows/persistent-herdr-workspaces.md) | Inspect an existing workspace before opening or typing into a role pane. |
| A regression, fixture, CI result, or hardware validation | [Verification Strategy and Hermetic Test Harness](/openwiki/testing/verification-strategy.md) | Run the narrowest existing test for the contract; a coverage gap is not a new requirement. |

## Entry points and safe investigation

The following are read-only investigation commands. They are appropriate before a change because they do not converge desired state, download artifacts, restart the service, load a model, or open a workspace:

```bash
./setup-qwen38-pi.sh show-config
./setup-qwen38-pi.sh plan
./setup-qwen38-pi.sh status --json
./setup-qwen38-pi.sh model-catalog
./setup-qwen38-pi.sh perf-history
local-ai workspace list
local-ai workspace status "$PWD"
```

`show-config` displays effective values in **environment > saved `setup.env` > defaults** precedence. `plan` is a non-mutating review gate: it resolves artifact completeness, role routing, startup selection, generated-file ownership, runtime tools, OMP compatibility, and reboot state. A nonzero plan is a result to resolve, not authorization to force `apply`.

`status [--json]` is an observational control-plane probe, not a generation test. It queries the catalog with `autoload=0`, compares keyless and keyed protected-chat responses, and reports service, model, configuration, and reboot state. A healthy status does not establish useful model output; use an intentional smoke operation when that is the question.

Herdr's `list` and `status` are also observational: when its server is stopped, they report that fact and an empty workspace list rather than starting it or changing its registry. This is distinct from `workspace open`, which can start or repair a persistent layout, and from `run`, `agent`, and `delegate`, which can send work into a terminal. See the workspace page before using those commands.

## Lifecycle changes are deliberately disruptive

Use normal desired-state convergence only after a fresh review. Downloading a tier makes artifacts available; it does not expose the tier through the generated router until `apply`.

```bash
./setup-qwen38-pi.sh model coder
./setup-qwen38-pi.sh plan
./setup-qwen38-pi.sh apply
```

For a supported setting, save, review, then activate:

```bash
./setup-qwen38-pi.sh save-config ROUTING_PROFILE=quality
./setup-qwen38-pi.sh plan
./setup-qwen38-pi.sh apply
```

`apply` reruns `plan` under the mutation lock. It snapshots saved configuration, OMP routing, managed launchers, and service files; persists configuration and regenerates applicable routing/launchers before service activation; and restores prior state on a failure or interruption. Do not substitute a plan obtained earlier for this preflight. Use focused `service` or `routing [--force]` repair only after reading the lifecycle and ownership pages—custom, mixed, or symlinked generated bundles are protection boundaries.

All dispatched mutating lifecycle and system operations share a private per-user lock because their artifact roots, configuration, generated files, service state, and host operations can contend. A live owner causes the competing operation to fail rather than race; wait for it to finish.

| Command family | Effect requiring deliberate scheduling |
|---|---|
| `model [tier|all]`, `model-verify`, `save-config`, `apply`, `service`, `routing`, `agent`, `herdr` | Writes artifacts, receipts, desired state, generated integration, service inputs, agent tools, or workspace runtime/configuration. |
| `model-remove`, `model-prune`, `model-maintain` | Destructive artifact maintenance. Prefer coordinated maintenance when a router may be active. |
| `smoke [tier]` | Checks authentication then sends an authenticated chat request for a complete tier; it can load or swap residency. |
| `perf [tier] [--keep]` | Measures the deployed API and manages residency unless explicitly retained. |
| `bench [tier] [--manage-service]` | Runs raw `llama-bench`; the managed form stops an active router and restores its former service state. |
| `local-ai workspace open`, `run`, `agent`, `delegate` | Creates/repairs persistent terminal layout or submits explicit work to role panes. They are not setup-engine lifecycle commands and may leave project processes running. |
| `kernel-tweaks`, `remote`, `ssh-harden` | Changes host policy or system-facing configuration; follow the system/security operation path. |

## Validate the changed contract

The portable baseline is hermetic:

```bash
bash tests/run.sh syntax
bash tests/integration/command-contract-test.sh
bash tests/e2e/workflow-test.sh
bash tests/run.sh offline
RUN_LOCAL_AI_E2E=1 bash tests/run.sh all
```

`tests/run.sh syntax` parses repository shell programs. The default `offline` target runs syntax plus sorted unit, integration, and end-to-end groups without requiring network access, `sudo`, systemd, or model files. `all` considers hardware tests only when `RUN_LOCAL_AI_E2E=1`.

Choose the smallest test that exercises the changed boundary, then expand to `bash tests/run.sh offline` for cross-layer edits. The command-contract test protects non-mutating `plan` and `status` in an absent-runtime fixture. The workflow test derives byte-sized artifacts while retaining the production manifest's tier, variant, ID, shard, and artifact-kind relationships. For workspace changes, begin with `tests/integration/herdr-install-test.sh` and/or `tests/integration/herdr-workspace-test.sh`; for router/service changes, use the focused operations or generated-config tests selected by the verification page. Hardware checks validate the actual workstation, but do not turn unavailable coverage into a required feature.

## Minimal safe-change checklist

1. Identify the owner in the routing map and read that page.
2. Capture `show-config`, `plan`, and `status --json` before an engine mutation; use workspace `list`/`status` before terminal work.
3. Make one bounded change through its owning source contract or command.
4. Run a fresh `plan` and resolve gates rather than bypassing them.
5. Use `apply` for normal desired-state convergence; run a live smoke, performance, benchmark, or workspace action only when it is the explicit thing being validated.
6. Run the narrowest relevant existing test, retain failure output, and expand to the hermetic offline suite when the change crosses layers.
