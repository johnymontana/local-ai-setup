---
type: "Reference"
title: "Example: acquire an optional tier without exposing it to the active router."
openwiki_generated: true
verified:
  - by: openwiki/0.5.0
    at: 2026-09-07T19:27:17.811Z
sources:
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
generated: { by: "openwiki/0.5.0", at: "2026-09-07T19:27:17.811Z" }
---


Use this page to choose the smallest safe path through the local AI stack. The scriptable authority is `./setup-qwen38-pi.sh`; `./manage.sh` is its interactive control panel, not a second implementation. The stack serves local coding agents through an authenticated router and is designed for one resident model, so an apparently small model or routing change can alter generated agent configuration and live service state.

## Start with the task, not the command

| If you need to… | Read first | Then use |
|---|---|---|
| Understand components, generated files, ownership, and the loopback API | [Runtime Stack and Ownership Boundaries](/openwiki/architecture/runtime-stack.md) | `./setup-qwen38-pi.sh status --json` or `./setup-qwen38-pi.sh show-config` to inspect the current system. |
| Change a setting, add/remove a tier, or converge desired state | [Model, Desired-State, and Apply Lifecycle](/openwiki/workflows/model-and-desired-state-lifecycle.md) | Make the bounded change, then `plan`; only `apply` after its gates resolve. |
| Change a locked artifact, config invariant, path, credential, or residency behavior | [Configuration, Artifacts, and Safety Invariants](/openwiki/concepts/configuration-artifacts-and-safety.md) | Preserve manifest integrity, private regular-file ownership, and `MODELS_MAX=1`; use the focused artifact/config tests. |
| Change generated OMP/pi integration or role selection | [Coding Agents and Model Role Routing](/openwiki/integrations/coding-agents-and-role-routing.md) | Review the generated-provider contract and test routing/launcher ownership before applying. |
| Diagnose API health, run a real generation, or measure performance | [Router Health, Smoke Tests, and Performance Operations](/openwiki/operations/router-health-and-performance.md) | Inspect status first; use `smoke`, `bench`, or `perf` only when their live effects are intended. |
| Change host tuning, LAN access, or SSH policy | [Host Tuning and LAN Access Security](/openwiki/operations/system-and-lan-security.md) | Treat `kernel-tweaks`, `remote`, and `ssh-harden` as privileged/system operations, with their dedicated transaction checks. |
| Select or extend a regression test | [Verification Strategy and Hermetic Test Boundaries](/openwiki/testing/verification-strategy.md) | Start with the narrowest affected test; use the hermetic suite before relying on workstation hardware. |

## Inspect without changing state

Begin every investigation with the read-only surface:

```bash
./setup-qwen38-pi.sh show-config
./setup-qwen38-pi.sh plan
./setup-qwen38-pi.sh status --json
./setup-qwen38-pi.sh model-catalog
./setup-qwen38-pi.sh perf-history
```

`show-config` displays effective precedence—environment, then saved `setup.env`, then defaults. `plan` resolves tiers, role routing, startup state, ownership, tool compatibility, and reboot gates without writing files or changing services. An unresolved plan is useful diagnostic output: correct the reported gate rather than forcing the next step.

`status` is observational too. It probes the router catalog with `autoload=0`, reports service/API/authentication state and tier artifact/runtime state, and must not be used as a model-load check. A healthy API result means both that keyless protected chat is rejected and that the configured key and catalog query work; it does not prove generation quality.

`model-verify` is intentionally different from ordinary inspection: it fully hashes selected installed artifacts and can refresh verification receipts, but does not restart the service. Use it when changing or auditing artifact bytes, not as a routine preflight.

## Change through the lifecycle boundary

For ordinary desired-state work, keep acquisition, review, and activation separate:

```bash
# Example: acquire an optional tier without exposing it to the active router.
./setup-qwen38-pi.sh model coder

# Review the resolved state and every gate.
./setup-qwen38-pi.sh plan

# Only after a successful review, generate/activate the coordinated state.
./setup-qwen38-pi.sh apply
```

For a supported setting, persist only a validated assignment, then repeat the same review/apply boundary:

```bash
./setup-qwen38-pi.sh save-config ROUTING_PROFILE=quality
./setup-qwen38-pi.sh plan
./setup-qwen38-pi.sh apply
```

`save-config` writes desired state but does not make it live. `apply` reruns the plan while holding the mutation lock, snapshots the affected desired, routing, launcher, preset, and unit files, then refreshes generated agent state and restarts the router. If its preflight fails, it makes no desired or live change; if a later phase fails, it restores the snapshots. Do not substitute a stale prior plan for the plan run by `apply`.

Use lower-level `service` and `routing [--force]` only for focused repair after reading the lifecycle and integration pages. In particular, custom, mixed, or symlinked generated files are protection boundaries: normal apply preserves them and reports a gate rather than silently taking ownership.

### Operations that are not inspection

| Operation | Intended effect and safe use |
|---|---|
| `model [tier|all]` | Downloads and verifies locked artifacts. It changes disk state but does not add the tier to the active generated router until `apply`. |
| `model-remove`, `model-prune` | Destructive artifact maintenance. Prefer `model-maintain remove <tier>` or `model-maintain prune` when a router may be active so stop, maintenance, plan, and apply remain coordinated. Review the deletion plan and confirmation prompt. |
| `smoke [tier]` | Verifies the authentication wall and sends a chat request for a complete tier. It can autoload or swap the resident model and may take minutes. |
| `bench [tier] [--manage-service]` | A raw benchmark. With `--manage-service`, it stops the managed router first and restores its prior service state afterward. |
| `perf [tier] [--keep]` | A live performance operation that manages model residency unless explicitly kept; do not treat it as a quiet unit test. |
| `kernel-tweaks`, `remote`, `ssh-harden` | Host or access-policy mutations. Follow the system/security workflow rather than running them as part of an application-only edit. |

All mutation-dispatch commands share a per-user operation lock. If the script reports another local-AI mutation, wait for it to finish rather than running competing downloads, apply, maintenance, or host changes.

## Choose validation that proves the change

Prefer the smallest quiet success signal that exercises the changed contract, but retain complete failure output. The default offline suite needs no network, `sudo`, systemd, or model files; real hardware tests are opt-in.

| Change boundary | First validation | Broader follow-up when warranted |
|---|---|---|
| Shell syntax only | `bash tests/run.sh syntax` | `bash tests/run.sh offline` if the edit affects behavior. |
| CLI spelling, command dispatch, read-only guarantees | `bash tests/integration/command-contract-test.sh` | `bash tests/run.sh offline`. |
| Validator/shared helper or interactive manager ordering | the matching file in `tests/unit/` such as `manager-test.sh` | the affected integration test, then offline. |
| Manifest/artifact verification, generated files, OMP routing, launchers, or API status schema | `bash tests/integration/generated-config-test.sh` | `bash tests/run.sh offline`. |
| Service readiness, locking, removal/pruning, benchmark restoration, or reboot gates | `bash tests/integration/operations-test.sh` | `bash tests/run.sh offline`. |
| Coordinated lifecycle and rollback | `bash tests/e2e/workflow-test.sh` | `bash tests/run.sh offline`. |
| Actual workstation/router/model behavior | targeted `status` then `smoke` for the changed installed tier | `RUN_LOCAL_AI_E2E=1 bash tests/run.sh all`; enable performance testing only when its disruption is acceptable. |

Do not redirect away failure output in a way that loses diagnostics. If a real `apply`, smoke, or hardware check fails, preserve its full output, inspect `journalctl --user -fu llama-server.service` for router failures, and return to `plan` before attempting another state-changing command.

## Minimal contributor checklist

1. Identify the state owner and read the linked domain page.
2. Inspect with `show-config`, `plan`, and `status --json` before mutation.
3. Make one bounded change; use `save-config` for supported desired settings and manifest-aware commands for artifacts.
4. Inspect a fresh `plan`; resolve—not bypass—its safety/ownership/reboot gates.
5. Use `apply` for normal convergence, then run only the focused operational check that proves the changed behavior.
6. Run the narrowest relevant test first and preserve failure output; expand to `bash tests/run.sh offline` when the change crosses layers.
