---
type: "Reference"
title: "Quickstart"
openwiki_generated: true
verified:
  - by: openwiki/0.5.0
    at: 2026-09-07T20:31:06.055Z
sources:
  - id: openwiki-source-03ffc32a0ca502ab67c54b25
    resource: repo://install.sh
  - id: openwiki-source-e845b6622635329fca37f1f6
    resource: repo://local-ai
  - id: openwiki-source-597ac7b7d26678e1e9c41f66
    resource: repo://manage.sh
  - id: openwiki-source-450df187d5ad439853de20f8
    resource: repo://setup-qwen38-pi.sh
  - id: openwiki-source-37c158c9536a90efb6244860
    resource: repo://tests/e2e/workflow-test.sh
  - id: openwiki-source-7e7512e407094ae5459c27c3
    resource: repo://tests/integration/command-contract-test.sh
  - id: openwiki-source-069e6674f1853a4ec99c387e
    resource: repo://tests/run.sh
generated: { by: "openwiki/0.5.0", at: "2026-09-07T20:31:06.055Z" }
---


This is the contributor starting point for the Omarchy-focused local coding stack. Use the scriptable engine, `./setup-qwen38-pi.sh`, as the implementation and automation boundary. `./manage.sh` is the keyboard-first interactive panel over that same engine; it is not a second lifecycle implementation.

For an initial workstation install, inspect the checkout and run `./install.sh` as the desktop user. It delegates to the engine's `all` baseline. After installation, `local-ai menu` opens the panel, `local-ai logs` follows `llama-server.service`, and other `local-ai` subcommands pass through to the engine.

## Route the task to its state owner

| If the task is about… | Read this page first | Safe next step |
|---|---|---|
| Entry points, ownership boundaries, generated files, or the local router | [Runtime Stack and Ownership Boundaries](/openwiki/architecture/runtime-stack.md) | Identify the owner before editing a generated file or wrapper. |
| Configuration precedence, pinned artifacts, receipts, symlinks, or managed-file takeover | [Configuration, Model Artifacts, and Managed-File Safety](/openwiki/concepts/configuration-artifacts-and-safety.md) | Preserve validation and ownership boundaries; do not hand-edit protected generated state. |
| Adding/removing a tier, saved desired state, planning, apply, or recovery | [Model and Desired-State Lifecycle](/openwiki/workflows/model-and-desired-state-lifecycle.md) | Separate artifact acquisition from activation and use a fresh `plan` before `apply`. |
| OMP/pi installation, tier launchers, role mapping, or remote agent sessions | [Coding Agents and Role Routing](/openwiki/integrations/coding-agents-and-role-routing.md) | Check the generated-provider and launcher contract before changing routing. |
| Router readiness, API/auth state, smoke generation, or performance | [Router Health and Runtime State](/openwiki/operations/router-health-and-performance.md) | Inspect `status --json` before intentionally running a live operation. |
| Kernel/TTM tuning, LAN remote access, firewall, SSH, or host policy | [System and LAN Security Operations](/openwiki/operations/system-and-lan-security.md) | Treat `kernel-tweaks`, `remote`, and `ssh-harden` as privileged system changes. |
| A regression test, fixture, CI signal, or real-hardware check | [Verification Strategy and Hermetic Test Harness](/openwiki/testing/verification-strategy.md) | Run the narrowest relevant hermetic test first, then expand coverage. |

## Start by inspecting, not converging

Run these from the repository checkout when investigating current state:

```bash
./setup-qwen38-pi.sh show-config
./setup-qwen38-pi.sh plan
./setup-qwen38-pi.sh status --json
./setup-qwen38-pi.sh model-catalog
./setup-qwen38-pi.sh perf-history
```

`show-config` presents effective settings in environment, saved `setup.env`, then default precedence. `plan` is read-only: it resolves installed artifacts, role routing, startup selection, ownership, runtime-tool, OMP, and reboot gates without changing files or services. A nonzero plan is a review result, not a prompt to force an apply: resolve its missing complete tier, selected-but-incomplete everyday variant, unavailable startup tier, custom generated state, incompatible dependency, or reboot gate.

`status [--json]` is observational, but it is a control-plane probe rather than a generation check. It queries the model catalog with `autoload=0`, probes protected chat both without and with the local key, and reports service, authentication, model/artifact/runtime, configuration, and reboot information. It can identify an insecure conflicting loopback listener even if the managed user unit is inactive; it does not prove that a model can generate a useful response.

## Make ordinary changes through the lifecycle

Keep download, review, and activation separate. For example, acquiring a specialist tier does not by itself expose it through the generated router:

```bash
./setup-qwen38-pi.sh model coder
./setup-qwen38-pi.sh plan
./setup-qwen38-pi.sh apply
```

For a supported setting, persist a validated value and repeat the review boundary:

```bash
./setup-qwen38-pi.sh save-config ROUTING_PROFILE=quality
./setup-qwen38-pi.sh plan
./setup-qwen38-pi.sh apply
```

`apply` reruns preflight under the mutation lock; do not rely on an earlier successful plan. It coordinates saved configuration, applicable OMP routing, launchers, and service generation, with snapshots and recovery for its managed state. Use lower-level `service` or `routing [--force]` only for focused repair after reading their owner pages. In particular, a custom, mixed, or symlinked routing/service bundle is a protection boundary rather than an invitation to overwrite it.

All dispatched mutating lifecycle and system operations share one private per-user operation lock because they can contend for common configuration, generated files, artifacts, service state, or system access. A live lock owner causes the competing command to fail; wait for it rather than overlapping model acquisition, apply, maintenance, or host changes.

### Operations with intentional live effects

| Command | Why it is not ordinary inspection |
|---|---|
| `model [tier|all]` | Downloads and verifies locked artifacts, changing disk state; use `apply` separately to converge router configuration. |
| `model-remove`, `model-prune`, `model-maintain` | Destructive artifact maintenance. Read the lifecycle safeguards and use the coordinated maintenance path when a router may be active. |
| `smoke [tier]` | Requires a complete tier, verifies the authentication wall, then sends an authenticated chat request. It can load or swap the resident model. |
| `bench [tier] [--manage-service]` | Runs raw `llama-bench`; with `--manage-service`, it stops the managed router when active and restores its prior active state afterward. |
| `perf [tier] [--keep]` | Measures the deployed API and manages residency unless retention is explicitly requested. Schedule it as a disruptive operation. |

## Validate the boundary you changed

The portable default is deliberately hermetic:

```bash
bash tests/run.sh syntax
bash tests/integration/command-contract-test.sh
bash tests/e2e/workflow-test.sh
bash tests/run.sh offline
RUN_LOCAL_AI_E2E=1 bash tests/run.sh all
```

`tests/run.sh syntax` parses repository shell scripts. Its default `offline` target runs syntax plus sorted unit, integration, and end-to-end groups and must not require network access, `sudo`, systemd, or model files. `all` adds hardware tests only when `RUN_LOCAL_AI_E2E=1`.

Choose the smallest test that exercises the changed contract. The command-contract integration test protects the non-mutating `plan` and `status` contract in an absent-runtime fixture. The workflow test rebuilds a byte-sized lock fixture while retaining production tier, variant, model-ID, shard, and artifact-kind relationships, then exercises coordinated lifecycle behavior. Use the linked verification page to select more focused generated-config, operations, security-transaction, or manager tests.

## Minimal change checklist

1. Identify the owner in the routing map and read that domain page.
2. Capture `show-config`, `plan`, and `status --json` before a mutation.
3. Make one bounded change through the owning command or source contract.
4. Run a fresh `plan`; resolve gates rather than bypassing them.
5. Use `apply` for normal desired-state convergence, then run only the intentional operational check required to prove the result.
6. Run the narrowest relevant test, preserve failure output, and expand to `bash tests/run.sh offline` for cross-layer changes.
