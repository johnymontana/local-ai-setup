---
type: safety invariants
title: Configuration, Artifacts, and Managed-File Safety
description: Configuration precedence, locked model artifacts, verification receipts, and managed-file ownership rules for the local inference deployment. Explains the validation, symlink defenses, and transactions that preserve user state and safe runtime changes.
tags: [configuration, artifact-integrity, managed-files, filesystem-security, local-inference]
sources:
  - id: openwiki-source-d22d02e8e24282f97a11370f
    resource: repo://herdr.lock
  - id: openwiki-source-3bd2ed3dac4f5554f20e6944
    resource: repo://lib/local-ai-common.sh
  - id: openwiki-source-2e9ec2f9c4214d7a3a160f3d
    resource: repo://lib/local-ai-desktop.sh
  - id: openwiki-source-59c4ee3de11f11823df478c4
    resource: repo://lib/local-ai-herdr.sh
  - id: openwiki-source-8cdd30afc64cff2f9cb15c13
    resource: repo://models.lock
  - id: openwiki-source-450df187d5ad439853de20f8
    resource: repo://setup-qwen38-pi.sh
  - id: openwiki-source-f1a57dc2ee647a64865101ee
    resource: repo://tests/integration/generated-config-test.sh
  - id: openwiki-source-7f5d8ea0d462cd0d3512ec0c
    resource: repo://tests/integration/herdr-install-test.sh
  - id: openwiki-source-a3837d24a42598759124dd51
    resource: repo://tests/integration/system-transaction-test.sh
  - id: openwiki-source-f381d2986802f05dd46ae1ad
    resource: repo://tests/unit/config-test.sh
  - id: openwiki-source-e2d2a8f6e4c32e2d28e657d4
    resource: repo://tests/unit/runtime-safety-test.sh
  - id: openwiki-source-ecf6c3ee8bf187c4144f6437
    resource: repo://tests/unit/user-config-preservation-test.sh
generated: { by: "openwiki/0.5.0", at: "2026-09-08T03:08:40.315Z" }
verified:
  - by: openwiki/0.5.0
    at: 2026-09-08T03:08:40.315Z
---

> **Invariant-oriented guide.** The setup engine is deliberately conservative: a value, artifact, or generated file is usable only after it satisfies the applicable validation and ownership checks. A refusal is normally a request for explicit operator action, not an invitation to overwrite, follow, or guess.

## Configuration is desired state, with explicit precedence

`setup-qwen38-pi.sh` is the authoritative resolver. It first records which supported keys were explicitly present in the process environment, reads only allowlisted keys from `setup.env`, and uses persisted values only where no explicit environment value exists. Defaults are applied afterwards. Therefore the effective order is:

1. explicit environment variable;
2. `SETUP_ENV` (by default `~/.config/local-ai/setup.env`);
3. built-in default.

The allowlist is `CONFIG_KEYS`; values outside it in the saved file are ignored. This makes `setup.env` a compact, engine-owned desired-state file rather than a shell script to source. `save-config K=V ...` validates the resolved configuration before persistence, stages the complete allowlisted set in the config directory, protects it as `0600`, and atomically renames it into place. The directory is protected as `0700` when saved or service state is generated.

The engine will not read or replace a symlinked `setup.env`, nor accept a directory or other non-regular object at that path. It makes the same distinction when it reacquires the per-user lifecycle lock and merges current persisted state: this prevents a wait behind another mutation from losing a concurrent save, while preserving higher-precedence environment inputs.

### Persisted tunables versus run-only controls

The persisted allowlist includes the selected agent/model and the values used to generate routing and service state: contexts, `PORT`, `MODELS_DIR`, reasoning and draft settings, `MODELS_MAX`, routing/startup/load/cache profiles, download and disk reserve settings, GTT size, and pinned `PI_VERSION`/`OMP_VERSION`. The following operational controls are deliberately **not** persisted: `ALLOW_PENDING_REBOOT`, `SERVICE_READY_TIMEOUT`, `SERVICE_HEALTHCHECK`, and `PERF_PROMPT_WORDS`. They must be supplied in the environment for the invocation that needs them; in particular, health checks can be disabled only as `SERVICE_HEALTHCHECK=0`, which is reserved for controlled tests.

Legacy saved values receive narrow compatibility migration: a non-explicit saved `REASONING_EFFORT=none` becomes `medium`, and a saved numeric `MODELS_MAX>1` becomes `1`. An explicit invalid value still fails. This preserves operability of older desired state without creating a one-run loophole.

### Validation boundaries that matter

Validation is not merely UI input checking; it protects values later embedded in generated shell and systemd artifacts.

| Area | Contract |
|---|---|
| Agent and routing | `AGENT` is `omp` or `pi`; `ROUTING_PROFILE` is `sticky`, `balanced`, or `quality`; `STARTUP_TIER` is a named tier or `none`. |
| Model selection and loading | Everyday `QUANT` is `UD-Q4_K_XL` or `Q8_0`; each tier load mode is one of `none`, `mmap`, `mlock`, `mmap+mlock`, or `dio`; KV cache is `f16` or `q8`. |
| Context and output headroom | Contexts are positive and no more than 262144. Everyday and coder require at least 32768 tokens; senior requires at least 65536, so their respective output ceilings still leave prompt/tool headroom. `DRAFT_N` is 1–8. |
| Resource bounds | `DOWNLOAD_JOBS` is 1–4, disk reserve is 1–128 GiB, and GTT is 64–115 GiB. The download-space check includes the remaining locked bytes **and** the reserve before `curl` can create a partial file. |
| Generated-path safety | `MODELS_DIR` must be absolute and cannot contain newline; combined model/home-derived generated paths reject quotes, `%`, `$`, backslashes, carriage returns, and newlines because they are systemd-significant. |

## The lock file defines the model artifact contract

`models.lock` is repository-owned, pipe-delimited data—not executable download logic. Its ten fields are:

```text
tier|variant|router_id|model_dir|repo|revision|remote_path|bytes|sha256|kind
```

Every row pins an immutable 40-hex revision, exact byte count, SHA-256 digest, and artifact kind (`main`, `draft`, or `mmproj`) in addition to the placement and router identity. The manifest validator rejects malformed field counts, duplicate destination basenames per tier, invalid identifiers, traversal/absolute remote paths, bad digest/revision shapes, unexpected tiers/kinds, and shapes other than the exact expected artifact sets.

The selected set for a tier is not always a single GGUF. `model_rows` includes the selected variant plus `ALL` rows, so the everyday tier requires its selected main quant **and** the MTP draft and vision projection. Coder requires four main shards and senior three. `tier_available` requires every selected row to be a regular, non-symlink file of the locked size; one missing shard makes the logical tier partial. Size establishes availability for catalog/routing decisions, then integrity verification establishes eligibility to serve.

### Artifact and receipt lifecycle

```mermaid
flowchart TD
  Lock["models.lock selected rows"] --> Check["validate manifest and disk reserve"]
  Check --> Fetch["HTTPS curl resume into artifact.part"]
  Fetch --> Part["partial file retained"]
  Part --> Resume{"part reaches locked byte count"}
  Resume -->|"no"| Fetch
  Resume -->|"yes"| Digest["verify size and SHA-256"]
  Digest -->|"match"| Promote["atomic rename to artifact"]
  Digest -->|"mismatch or oversized"| Retain["refuse and retain part for inspection"]
  Promote --> Receipt["write private v1 verification receipt"]
  Receipt --> Cached{"identity-bound receipt valid"}
  Cached -->|"yes"| Serve["eligible complete tier"]
  Cached -->|"no"| Rehash["full size and SHA-256 verification"]
  Rehash -->|"match"| Receipt
  Rehash -->|"fail"| Refuse["do not expose or serve tier"]
  Retain --> Refuse
```

*Artifact state transitions: partial data is resumable but not usable; only a verified regular file and a valid receipt can take the cached path to service generation.*

The downloader refuses symlinks for both destination and `.part` paths, and refuses an existing non-regular destination. A complete existing artifact is reused only after full size/digest verification. A `.part` that already verifies is promoted locally, recovering a crash after the last byte before rename. A short `.part` is resumed over HTTPS only (`--proto '=https'`, redirects constrained to HTTPS, TLS 1.2 minimum); a complete-but-corrupt or oversized `.part` is retained and causes refusal rather than append or silent replacement. Post-download verification failure likewise retains evidence for inspection.

A successful full verification writes a private receipt under `~/.config/local-ai/verified-models` by default. Its `v1` record contains the exact path, expected size, expected digest, and file identity. Identity includes device, inode, byte size, mtime, and ctime (with sub-second timestamps where available), so a replacement or same-size rapid overwrite invalidates a receipt without rehashing every routine operation. Cached verification still requires a regular non-symlink file and matching size. `model-verify` intentionally bypasses the receipt fast path and fully hashes selected installed artifacts; service generation may use the valid cached path but will rehash and refuse artifacts whose receipt no longer matches.

## Availability, residency, and destructive operations

A partial tier is visible as partial in `model-catalog`, but it is not a routing/provider candidate. `cmd_service` verifies every size-complete tier against the lock before generating service state, excludes incomplete/wrong-size tiers, and fails if none are complete. It also refuses a selected-but-incomplete everyday quant rather than letting another tier conceal a `QUANT` selection change, and refuses an unavailable non-`none` startup tier.

`MODELS_MAX=1` is enforced—not advisory—for the 128 GiB target. Explicit values other than one fail validation; legacy persisted values above one are migrated to one and saved as one. The generated router launcher consequently uses `--models-max 1`, while generated OMP routing also limits its task concurrency and llama.cpp provider in-flight requests to one. This common limit protects memory and avoids concurrent requests fighting a router that can host one model at a time.

Removal/pruning is also fail-closed. Before managed model files change, the service must either be not installed or prove `inactive`/`failed` with `MainPID=0`; active, transitioning, absent/unqueryable, or unknown states refuse the operation. Multi-shard paths are first validated and atomically renamed into a quarantine namespace; signal or rename failure restores the staged prefix. Only after all moves does cleanup unlink them. If maintenance began with the router active, a lifecycle transaction restarts the prior router only if an artifact namespace fingerprint proves no artifact state changed; otherwise it remains stopped until plan/apply succeeds.

## Secrets and generated filesystem boundaries

The loopback API is treated as a credential boundary. During service generation, `llama.key` must be a regular non-symlink path. If absent/empty the engine generates 32 random bytes encoded as hex, validates its safe 32-or-more-character token form, stages it at `0600`, and atomically installs it; otherwise it restricts the existing regular key to `0600` and validates it. `local_ai_curl_authenticated` obtains the key only from such a file and sends the authorization header through curl configuration on standard input, rather than embedding the bearer token in argv.

The user service makes the model tree read-only and applies `UMask=0077`, `NoNewPrivileges=true`, strict system protection, read-only home protection, private temporary storage, restricted namespaces/SUID behavior, protected kernel controls, and DRM-only device access. The service installation additionally stages and syntax-checks its launcher, optionally validates a staged unit with `systemd-analyze --user verify`, and regards readiness as the commit point. On install, restart, API authentication/catalog, warm-tier readiness, or managed-listener ownership failure, it restores the prior preset, launcher, unit, enablement, and active state.

Generated files have ownership boundaries, not overwrite-by-path semantics:

- The service preset, router launcher, and user unit are a **trio**. Ordinary regeneration requires every existing member to be a regular, non-symlink recognized managed file (or a recognized legacy trio); any custom, symlinked, mixed, or non-regular member blocks replacement.
- OMP `models.yml` and `config.yml` are a **pair**. If either is custom or a symlink, ordinary `routing` preserves both pair members and launchers, writes both generated candidates as `.local-ai-setup.example`, and returns status 2. `routing --force` is the explicit replacement path and first writes timestamped backups. Pair and wrapper updates snapshot and restore the entire routing bundle on failure or signal.
- Tier wrappers and `local-ai-agent` replace only marker-recognized regular files. Unmarked or symlinked user launchers are preserved. Wrappers for unavailable tiers are removed only if they carry the managed marker, preventing a stale managed command from selecting an absent alias.
- Managed shell exports are replaced by marker identity, rather than blind line deletion. An unmarked user export is retained and the managed export is appended last. A dotfile symlink is resolved only with `realpath` to a regular non-symlink target; its mode is preserved, while dangling/unresolved/non-regular links refuse integration.
- Desktop integration uses the same absent-or-marker-owned rule for its command wrapper and three desktop entries: menu, logs, and workspaces. It stages then renames managed regular files, while `desktop-remove` deletes only marker-recognized regular files and warns for user-owned or symlinked paths.

Not every file the setup can create is a managed file intended for later replacement. `ensure_pi_settings` and `ensure_tmux_config` install private (`0600`) starter files only when their paths are absent. Existing regular settings retain both content and mode; existing symlinks, dangling links, and other non-regular paths are left untouched with a warning. Users can therefore take ownership simply by creating or editing these conventional configuration files.

### Herdr has a separate locked-runtime and ownership boundary

`herdr.lock` is distinct from `models.lock`: it selects exactly one Linux x86_64 upstream release asset for the configured `HERDR_VERSION`, with an exact release URL, byte count, and SHA-256. `herdr` requires that lock entry and platform, downloads to a private staging directory over HTTPS, verifies size and digest before executing the staged binary to check its reported version, then installs the executable (`0700`) and its private receipt (`0600`) together. A normal invocation reuses only a binary whose two-line marked receipt still hashes to its recorded identity; replacing a different managed release requires `herdr-upgrade` explicitly.

The Herdr installer treats the runtime binary and receipt as one recoverable pair. It rejects symlinked or non-directory path components, modified/missing/unmarked runtime state, and failed staging checks without replacing the installed runtime. Once promotion begins, an EXIT or signal handler restores the previous binary and receipt (or removes both if they were newly created); recovery files remain if that restoration fails.

The same ownership predicate applies to the generated Herdr config, launchers, coordination skill, and agent lifecycle hooks. Parent paths must be safe absolute directories without symlinks; a file may be replaced only when absent or marked/receipted as the expected generated content. A custom Herdr configuration is retained and the candidate is emitted as `config.toml.local-ai-setup.example`; custom or symlinked launchers, skills, and hooks are preserved. The Herdr launcher deliberately unsets `LLAMA_API_KEY`, `LLAMA_BASE_URL`, and `LLAMA_CPP_BASE_URL` so a persistent session does not retain daemon credentials.

## Coordinated apply and root-operation rollback

`apply` first reruns `plan`; a previously viewed plan does not authorize writes after configuration, artifacts, or ownership changed. It snapshots `setup.env`, the OMP pair, selected and tier launchers, and the service trio before saving desired configuration, refreshing applicable routing and the selected-agent launcher, then invoking the nested service transaction. A failure before the service phase restores desired/routing state without touching the router; a later failure also restores the service files and prior enabled/active state. If a rollback cannot finish, recovery copies remain in the transaction directory instead of being silently discarded.

Root-facing changes use the same transaction principle. The SSH drop-in update snapshots the previous policy, validates a staged policy before reload, and restores the prior file, mode, and—when relevant—daemon policy on failure or signal. Kernel GTT work similarly snapshots both current and legacy modprobe policy paths; an interrupted or failed initramfs rebuild restores their prior state and rebuilds the prior boot image. Both refuse symlinked policy targets rather than following centrally managed links.

## Focused verification and safe change practice

The focused tests make the most important boundaries executable:

- `tests/unit/config-test.sh` checks documented defaults, accepted and rejected enums, native context and output-headroom bounds, single residency, download limits, health-check values, and systemd-sensitive model paths.
- `tests/unit/user-config-preservation-test.sh` verifies that initial Pi and tmux files are private, while existing regular content/modes and both valid and dangling symlinks remain untouched.
- `tests/integration/system-transaction-test.sh` uses mocked system commands to verify SSH policy rollback on TERM and EXIT, host-key preparation without opening an inactive daemon, and recovery of current/legacy kernel policy plus initramfs after interruption or rebuild failure. It also confirms a symlinked kernel policy is preserved without a rebuild.
- `tests/integration/generated-config-test.sh` supplies the broader generated-state regression coverage: locked/partial artifact behavior, receipt invalidation, config/key path refusal, managed ownership gates, and service/OMP rollback.
- `tests/integration/herdr-install-test.sh` supplies a hermetic locked-release fixture and checks staged runtime/receipt promotion and rollback, required explicit upgrades, modified/symlink preservation, safe parent traversal, and removal of inherited API credentials from persistent-session launchers.

When changing these mechanisms, keep the order of checks meaningful: validate configuration and ownership before persistence or mutation; validate space before network writes; verify content before promotion/exposure; and snapshot a coherent group before changing any member. Do not weaken a refusal into automatic cleanup or replacement merely to make an idempotent run appear successful.

## Related pages

- [Runtime Stack and Ownership Boundaries](/openwiki/architecture/runtime-stack.md)
- [Coding Agents and Role Routing](/openwiki/integrations/coding-agents-and-role-routing.md)
- [System and LAN Security](/openwiki/operations/system-and-lan-security.md)
- [Quickstart](/openwiki/quickstart.md)
- [Verification Strategy](/openwiki/testing/verification-strategy.md)
- [Model and Desired-State Lifecycle](/openwiki/workflows/model-and-desired-state-lifecycle.md)
