# Performance and developer-experience implementation plan

This plan turns the adversarial review into explicit behavior and acceptance
criteria. It is intentionally test-oriented: a change is complete only when
its unit policy, generated integration surface, and operator workflow are all
covered.

## Primary findings

| # | Risk | Implementation | Acceptance criteria |
|---:|---|---|---|
| 1 | Two or three resident large models can exhaust 128 GiB | Enforce and persist `MODELS_MAX=1` for this 128 GiB target; migrate unsafe legacy saved values back to one instead of generating a persistent unsafe service | Boundary tests reject every value above one; generated launcher contains one; legacy migration remains operable |
| 2 | Automatic role routing causes multi-tens-of-GiB cold-swap thrash | Make `sticky` the default; add `balanced` and `quality`; keep deterministic `omp-{everyday,coder,senior}` phase launchers | Role-matrix tests cover every profile and missing-tier fallback; sticky never selects an optional tier automatically |
| 3 | Blanket `load-mode=none` slows every swap without evidence | Keep AMD's measured everyday default `none`; default coder/senior to `mmap`; validate the five llama.cpp modes per tier | Preset tests assert independent modes and reject the nonexistent `auto` mode; raw/perf output records the selected mode |
| 4 | Routine service and benchmark commands reread 133+ GiB | Write private verification receipts bound to lock digest, path, size, device/inode, mtime, and ctime; use receipts for routine operations; keep `model-verify` unconditional | Tests prove a valid receipt skips hashing, metadata changes invalidate it, and explicit verification always hashes |
| 5 | A 640-token kernel benchmark does not represent production routing | Keep `bench` as a clearly labeled pp512/tg128 kernel baseline; add authenticated `perf` for cold load, first response, warm re-prompt, production preset, token usage, residency restoration, and comparable history | Mocked end-to-end tests cover timing capture, metrics JSONL, prior-state restoration on success/failure/signal, and `--keep` |
| 6 | Disabling OMP's pruning inflates prompts and swap re-prefill | Use OMP's cache-aware `supersedeReads` and `dropUseless` defaults; stop emitting the disabling overrides | Generated-config tests reject both false overrides and preserve custom OMP pairs atomically |
| 7 | Eager everyday loading plus HTTP 503 can report a false-ready service | Add `STARTUP_TIER=everyday|coder|senior|none`; distinguish router-up from model-ready; wait for the selected model or roll back | Readiness tests cover no-startup, loaded, loading, timeout, crash, and transactional rollback |
| 8 | Unbounded context and MTP values can cause avoidable OOMs | Cap all contexts at 262,144 and MTP draft depth at 1–8 (default four); validate before persistence or mutation | Unit boundary tests and non-mutation integration tests cover every limit |
| 9 | Serial split downloads waste available bandwidth | Add bounded `DOWNLOAD_JOBS=1..4` (default two), aggregate disk preflight, resumable verified `.part` handling, and failure propagation | Mock download tests cover the concurrency bound, resume, complete promotion, corrupt/oversized/symlink rejection, and partial-state reporting |
| 10 | No-argument execution and permissive arity make expensive actions easy to trigger accidentally | Make no arguments show help; require explicit `all`; validate every command's options/arity; separate read-only `plan`/`status` from mutating `apply`/`smoke` | Command-contract tests exercise help, missing/extra arguments, exit codes, and filesystem/service non-mutation |

## Secondary improvements

- Treat saved configuration as desired state. `plan` previews it without
  persistent writes; `apply` preflights dependencies, stages service and
  routing changes, and restores desired, routing, service files, and service
  state after a failure or interruption.
- Serialize every mutating lifecycle command across processes so downloads,
  removal, apply, smoke, and performance residency cannot race one another.
- Download and verify a prospective everyday quant before persisting `QUANT`.
- Publish a stable `status --json` schema. A green API state requires both an
  unauthenticated protected-request rejection and a successful authenticated
  protected request; status never loads a model.
- Keep `smoke` as the explicit targeted model-load/generation check.
- Show installed, partial, loading, loaded, sleeping, failed, and unloaded
  states plus byte progress and reboot-required state.
- Add `model-remove` and `model-prune` with exact manifest ownership,
  no-follow deletion of managed-path symlinks, preservation of custom ownership
  boundaries, confirmation, stopped-router guards, and a required startup
  transition before deleting the warm tier.
- Preserve a configurable free-space reserve and preflight the aggregate
  remaining bytes before an all-tier download.
- Add `KV_CACHE_PROFILE=f16|q8`, per-tier load controls, routing/startup
  profiles, and bounded download controls to the interactive manager.
- Preserve custom OMP configuration as an atomic pair, still install safe
  shell/auth integration, remove only the exact obsolete managed export, and
  provide launchers that work without reopening a shell.
- Provide an explicit package/agent upgrade path and stop before GPU/service
  activation when the running kernel or TTM limit requires a reboot.
- Extract shared Bash-3.2-compatible helpers for config reads, file identity,
  option/version parsing, API-key validation, and private authenticated curl.
- Bind fast verification receipts to sub-second mtime/ctime identity and make
  production performance require the active preset, recording quant and
  artifact-set identity in comparisons.
- Run pinned, least-privilege CI with syntax, ShellCheck, unit, integration,
  and offline end-to-end tests. Keep real Strix Halo/model tests opt-in because
  they require Arch, systemd user services, Vulkan, and hundreds of GiB.

## Test layers

| Layer | Runs by default | Responsibility |
|---|---|---|
| Unit | Yes | Configuration boundaries, profile matrices, helpers, receipts, HTTP-state truth tables, argument parsing |
| Integration | Yes | Generated presets/service/OMP files, transaction rollback, downloader mocks, status schema, manager delegation |
| Offline end to end | Yes | Desired config → plan → apply → status → smoke/perf using hermetic command and HTTP mocks |
| Hardware end to end | Opt-in | Authenticated real-service status, smoke generation for every installed tier, optional production perf recording, and authenticated post-run restoration |

The portable entry point is `bash tests/run.sh offline`. Hardware cases require
`RUN_LOCAL_AI_E2E=1 bash tests/run.sh all` on the target workstation and must
never run in ordinary pull-request CI. Vulkan offload placement, memory
headroom, and MTP acceptance-rate interpretation remain explicit operator
benchmark work rather than assertions in the portable hardware smoke harness.
