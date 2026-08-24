# Local agentic coding on a Framework Desktop: Qwen 3.8 27B + pi/omp on Arch Linux

A tutorial and repeatable setup for running a fully local coding agent on the
Framework Desktop (AMD Ryzen AI Max+ 395 "Strix Halo", 128GB unified RAM):
[Qwen 3.8 27B](https://huggingface.co/Qwen/Qwen3.8-27B) served by
[llama.cpp](https://github.com/ggml-org/llama.cpp) over Vulkan, driven by your
choice of coding agent — [pi](https://pi.dev) (minimal, fast) or
[oh-my-pi / omp](https://github.com/can1357/oh-my-pi) (IDE wired in: LSP,
debugger, subagents). No cloud, no API keys, no telemetry — your code never
leaves the machine.

**TL;DR — the easy way**

```bash
chmod +x manage.sh setup-qwen38-pi.sh
./manage.sh        # interactive menu: pick pi or omp, run setup, tune, remote access
```

**TL;DR — scripted**

```bash
./setup-qwen38-pi.sh save-config AGENT=omp   # or AGENT=pi (default)
./setup-qwen38-pi.sh all                     # packages, model, server, agent
./setup-qwen38-pi.sh status                  # smoke-test the API
cd ~/some-project && omp                     # (or `pi`) — then give it a task
./setup-qwen38-pi.sh remote                  # optional: drive it from phone/laptop (LAN-only)
```

Everything the script does is explained below, and every step can be run (and
re-run — it's idempotent) individually. The interactive `./manage.sh` is just a
menu over these same subcommands.

---

## The interactive control panel (`./manage.sh`)

If you'd rather not memorize subcommands, `./manage.sh` is a menu-driven front
end over everything in this repo. It shows a live status header — selected agent
(pi/omp) and whether it's installed, the server state, whether the API is
reachable, and your current quant/context/reasoning — then lets you:

- run the **full setup**, or any single step (install, model, server, agent);
- **choose your agent** (pi ⇄ omp) and install it;
- **tune configuration** — reasoning effort, context window, quant, MTP draft
  depth — and restart the server to apply, all persisted to
  `~/.config/local-ai/setup.env`;
- set up **remote access**, **harden SSH**, install **LSP servers**, apply the
  **kernel GTT tweak**, run a **benchmark**, or view **status**.

It's a thin wrapper — every action just calls `./setup-qwen38-pi.sh <subcommand>`
and echoes the command it runs, so nothing is hidden and each step still works
standalone. The rest of this document explains what those steps do.

---

## Why this exact stack

**The model — Qwen 3.8 27B** (released August 2026, Apache 2.0) is the
open-weight sibling of Alibaba's 2.4T-parameter Qwen 3.8 Max, and it is
arguably the first local-sized model that is *designed* for agentic work
rather than adapted to it: 61.7% on SWE-bench Pro and 90.3% on LiveCodeBench
v6, with native vision (it can read your screenshots) and a 262,144-token
native context. Two architecture choices matter a lot on this hardware:

1. **Hybrid attention.** 48 of its 64 layers use linear-time Gated DeltaNet;
   only 16 are full attention. The KV cache at the *full* 262K context is
   ~16GB instead of the ~64GB a conventional dense 27B would need — long
   agentic sessions stay cheap.
2. **MTP (multi-token prediction).** The model ships with a built-in draft
   head. llama.cpp's MTP speculative decoding (merged May 2026) uses it to
   generate ~2× faster *losslessly* — drafts are verified by the main model,
   so output is identical, just faster. On Strix Halo this is the difference
   between ~12 t/s and ~25-35 t/s, i.e. between "painful" and "pleasant".

**The runtime — llama.cpp with Vulkan (RADV).** AMD's own day-0 guidance for
Qwen 3.8 on Ryzen AI Max uses the llama.cpp Vulkan backend, and on Arch it is
a first-class citizen: `llama-cpp` lives in `extra` and gets rebuilt every few
days, with GPU backends as plug-in packages (`ggml-vulkan`, `ggml-hip`). No
AUR, no containers, no ROCm version roulette — though ROCm is one package
away if you want to A/B it (see [Going further](#going-further)).

**The agent — pi.** A deliberately minimal, hackable coding agent
(read/bash/edit tools, extensions in TypeScript) with first-class llama.cpp
support: it talks to `llama-server`'s router mode, and its `/llama` command
can browse, download, load, and switch local models from inside the TUI.

---

## 0. Prerequisites

**Hardware/OS assumed:** Framework Desktop with Ryzen AI Max+ 395 and 128GB,
up-to-date Arch (kernel ≥ 6.16.9 — check with `uname -r`; anything current in
August 2026 qualifies), ~20-30GB free disk for the model.

**BIOS (one-time, and counterintuitive):** leave *iGPU Memory Allocation /
UMA Frame Buffer Size* at the **small default (512MB)** — do *not* crank it to
96GB. On Linux, llama.cpp allocates model memory dynamically from GTT
(GPU-translatable system RAM), not from the fixed BIOS carveout. A big
carveout just steals RAM from the OS. Optionally disable IOMMU in BIOS (or add
`amd_iommu=off` to the kernel cmdline later) for ~6% better memory bandwidth
if you don't need VFIO/passthrough.

**Memory model in one picture:**

```
128 GiB unified LPDDR5X (~256 GB/s)
├── 512 MiB  BIOS carveout ("VRAM" — display framebuffer only)
├── ~64 GiB  GTT, GPU-addressable out of the box (kernel default: 50% of RAM)
│            └── plenty for Qwen 3.8 27B Q4 + 128K context (~30 GiB)
└── rest     CPU/OS

optional kernel tweak (step 4) → raise GTT to ~115 GiB for Q8/262K/bigger models
```

## 1. Packages

```bash
sudo pacman -S --needed llama-cpp ggml-cpu ggml-vulkan vulkan-radeon \
                        vulkan-icd-loader vulkan-tools curl jq nodejs npm
```

`llama-cpp` is the server/CLI; `ggml-vulkan` is the GPU compute backend it
loads at runtime; `ggml-cpu` is **not optional** even though pacman thinks it
is — llama.cpp always needs the CPU backend as its base, and without this
split package every model load dies with `make_cpu_buft_list: no CPU backend
found`; `vulkan-radeon` is Mesa's RADV driver. Verify the GPU is visible:

```bash
vulkaninfo --summary | grep -i radv     # expect: AMD Radeon 8060S (RADV GFX1151)
llama-server --list-devices             # expect a Vulkan device
```

Keep this box updated — llama.cpp gains Strix Halo and Qwen 3.8 perf fixes
constantly, and on Arch that's just `sudo pacman -Syu`.

## 2. The model

We use [unsloth's GGUFs](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF):
their Dynamic v3 quants benchmark better than vanilla quants at the same size,
their chat template fixes are already baked in, and — confirmed by the unsloth
team — the MTP head is included in the main GGUF, so speculative decoding
needs no extra files.

| File | Size | When to use |
|---|---|---|
| `Qwen3.8-27B-UD-Q4_K_XL.gguf` | 16.4 GiB | **Default.** Best speed; quality holds up for agentic coding |
| `Qwen3.8-27B-Q8_0.gguf` | 27 GiB | Near-lossless; ~half the generation speed of Q4 |
| `mmproj-F16.gguf` | 0.9 GiB | Vision encoder — required for image input, always grab it |

The script downloads into `~/llm/models/Qwen3.8-27B/` with resume support and
verifies the exact byte sizes. Directory layout matters: the model and its
`mmproj` sit together in one subdirectory per model, which is how
`llama-server`'s router mode auto-pairs vision encoders and how pi's `/llama`
browser expects to find things.

Avoid quants below Q3 for this model: users report MTP acceptance collapses
and dequant overhead makes low-bit quants *slower*, not faster — and with
128GB there is zero reason to starve a 16GiB model.

## 3. The server

The script installs a systemd *user* service that runs this launcher
(`~/.local/bin/llama-qwen38-server`, generated — edit and
`systemctl --user restart llama-server` to tune):

```bash
llama-server \
  --host 127.0.0.1 --port 8080 \
  --models-dir ~/llm/models \       # router mode: serve everything in here
  --models-max 2 \
  --jinja \                         # correct chat template + tool calling
  --no-mmap \                       # recommended on Strix Halo unified memory
  -ngl 999 \                        # everything on the GPU
  -c 131072 \                       # 128K context (~8 GiB KV thanks to hybrid attention)
  -fa on \                          # flash attention
  -np 1 \                           # required for MTP speculative decoding
  --spec-type draft-mtp \           # use Qwen 3.8's built-in MTP head
  --spec-draft-n-max 4 \            # AMD's recommended draft depth on Ryzen AI Max
  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 \
  --chat-template-kwargs '{"reasoning_effort":"medium"}'
```

Why these flags:

**Router mode** (`--models-dir`, no `-m`) exposes an OpenAI-compatible API at
`http://127.0.0.1:8080/v1` that can list, load, and swap any GGUF under the
models dir on demand. pi drives this natively; it also means adding a second
model later is "drop the file in the folder", nothing else.

**`--jinja` is the template trap.** Qwen 3.8 needs its jinja chat template for
turn boundaries, `<think>` handling, and tool-call formatting. Current builds
enable it by default, but it stays explicit here because without it tool calls
silently degrade into rambling text — the single most common "my local agent
is broken" cause.

**Thinking budget.** Qwen 3.8 is a reasoning model with thinking on by
default; `reasoning_effort` (`xhigh` → `medium` → `low` → `none`) trades
answer quality against how long you wait watching `<think>` tokens.
`medium` is the sweet spot for interactive agentic coding at Strix Halo
speeds; bump to `xhigh` for gnarly refactors, drop to `none` (with sampling
`--temp 0.7 --top-p 0.8` and `--presence-penalty 1.5` per Qwen's
recommendation) if you want a fast non-thinking workhorse.

**MTP** (`--spec-type draft-mtp`): lossless ~2× generation speedup, but the
llama.cpp implementation is young (merged May 2026). If you hit weirdness
after an update, delete the two `--spec-*` lines — everything still works,
just slower. A slow memory creep over multi-day sessions has been reported by
some users; the unit file contains a commented `RuntimeMaxSec=86400` to
recycle the server daily if you ever see that.

Manage it like any service:

```bash
systemctl --user status llama-server
journalctl --user -fu llama-server        # watch model load / speed stats
loginctl enable-linger $USER              # script does this: keep server up when logged out
```

## 4. Optional: unlock (almost) all 128GB for the GPU

Stock kernels cap GTT at 50% of RAM (64GiB) — enough for the default setup.
To run Q8_0 at 262K context, BF16-class models, or 70B+ models later, raise
it. `./setup-qwen38-pi.sh kernel-tweaks` writes this (bootloader-agnostic,
works with systemd-boot and GRUB alike since it goes through modprobe rather
than the kernel cmdline), rebuilds the initramfs, and asks you to reboot:

```
# /etc/modprobe.d/99-strix-halo-llm.conf
options amdgpu gttsize=117760                          # ~115 GiB in MiB
options ttm pages_limit=30146560 page_pool_size=30146560   # same, in 4 KiB pages
```

Leave ~8-13GiB for the OS. Revert by deleting the file and running
`sudo mkinitcpio -P` again.

## 5. The agent (pi)

> Choosing **omp** instead? Skip to [5c](#5c-pi-or-omp-choosing-your-agent) /
> [5d](#5d-omp-comprehensive-local-qwen-configuration). The `./manage.sh` menu
> or `save-config AGENT=omp` makes the choice; the server steps above are shared.

```bash
curl -fsSL https://pi.dev/install.sh | sh
export LLAMA_BASE_URL=http://127.0.0.1:8080          # put both in ~/.bashrc
export LLAMA_API_KEY=$(cat ~/.config/local-ai/llama.key)   # server requires this (see Security)
```

Then, in any project:

```bash
cd ~/github/some-project
pi
```

Inside pi: `/llama` opens the model manager — you'll see `Qwen3.8-27B` with a
live status icon; load it (first load pulls 17GB into GTT, ~15-30s), then
`/model` to select it for the session, and give it a task. `/llama` can also
search and download new GGUFs from Hugging Face straight into your models dir.
If your pi build predates built-in llama.cpp support, `pi install
npm:pi-llama-cpp` adds it.

Because Qwen 3.8 is vision-native and the mmproj is loaded, you can paste
screenshots into pi (broken UI, error dialogs) and the model actually sees
them.

The next section covers pi's configuration in depth — settings, `AGENTS.md`
project instructions, custom commands, sessions, and (if you'd rather not use
the `/llama` router) a pinned `models.json`.

## 5b. Configuring pi (typical setups)

pi keeps everything under two roots: **global** config in `~/.pi/agent/`
(`settings.json`, `models.json`, `auth.json`, `trust.json`, `AGENTS.md`,
`prompts/`, and `sessions/`), and **per-project** config in a `.pi/` directory
that overrides the global one (nested objects merge). The `all` run writes a
starter `~/.pi/agent/settings.json` with telemetry off — everything below is
optional tuning on top of that.

### settings.json

Global at `~/.pi/agent/settings.json`, per-project at `.pi/settings.json`. The
keys people actually touch:

```json
{
  "defaultThinkingLevel": "medium",
  "compaction": { "enabled": true, "keepRecentTokens": 24000 },
  "enabledModels": ["Qwen3.8-27B", "claude-*"],
  "enableInstallTelemetry": false,
  "enableAnalytics": false,
  "theme": "dark",
  "steeringMode": "one-at-a-time"
}
```

`compaction` matters more with a local model than a cloud one: when the session
approaches the context window, pi summarizes the older turns instead of hard
-failing, so a long agentic session stays inside your `-c 131072`. `enabledModels`
is the list `Ctrl+P` cycles through. Note that for the local model, the *server's*
`reasoning_effort` (set in the launcher) is the real thinking-budget control —
`defaultThinkingLevel` is pi's own knob and mostly relevant when you also use
cloud models. Telemetry is off in the starter file; `--offline` (or
`PI_OFFLINE=1`) additionally skips all startup network calls.

### Wiring the model: two ways

**The `/llama` router (recommended)** — nothing to configure. Because
`llama-server` runs in router mode, pi's `/llama` command discovers, downloads,
loads, and unloads models live; `/model` picks the loaded one. This is why the
guide favors router mode: adding a model is "drop a GGUF in `~/llm/models/`",
never a config edit.

**A pinned provider in `models.json`** — if you'd rather not use `/llama`, or
want the model preselected. Lives at `~/.pi/agent/models.json`; `apiKey`
supports `$VAR` interpolation, so the API key stays out of the file:

```json
{
  "providers": {
    "local-llamacpp": {
      "name": "Local llama.cpp",
      "baseUrl": "http://127.0.0.1:8080/v1",
      "api": "openai-completions",
      "apiKey": "$LLAMA_API_KEY",
      "models": [
        {
          "id": "Qwen3.8-27B",
          "name": "Qwen 3.8 27B (local)",
          "reasoning": true,
          "input": ["text", "image"],
          "contextWindow": 131072,
          "maxTokens": 32768,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
```

(`api` accepts `openai-completions`, `anthropic-messages`, `openai-responses`,
and others; llama.cpp is OpenAI-compatible, so `openai-completions` is correct.)

### Project instructions: AGENTS.md

This is the highest-value config for coding quality. pi loads `AGENTS.md` (or
`CLAUDE.md`) from the project directory and every parent up the tree, plus a
global `~/.pi/agent/AGENTS.md`, as system context. Drop an `AGENTS.md` at a repo
root:

```markdown
# Project: acme-api

## Stack
Go 1.23, chi router, sqlc, Postgres. Module path github.com/acme/api.

## Commands
- build: `go build ./...`
- test:  `go test ./...`   (run after every change)
- lint:  `golangci-lint run`

## Conventions
- Table-driven tests; no naked returns; wrap errors with %w.
- Never edit generated files under internal/db/ — regenerate with `make sqlc`.
```

Precedence: `.pi/SYSTEM.md` replaces the built-in system prompt entirely;
`.pi/APPEND_SYSTEM.md` appends to it; `-nc` disables context files for one run.

### Custom slash commands (prompt templates)

A Markdown file in `~/.pi/agent/prompts/` (global) or `.pi/prompts/` (project,
after trust) becomes a command named after the file — `review.md` → `/review`.
Supports positional args (`$1`, `$@`) and YAML frontmatter:

```markdown
---
description: Review staged changes for bugs and missing tests
argument-hint: [focus]
---
Review the staged diff. Focus on $1 if given, else correctness and tests.
Run `git diff --staged`, list concrete issues, and propose fixes.
```

### Sessions

Auto-saved to `~/.pi/agent/sessions/`, grouped by working directory. Handy
commands and flags:

| Do this | Command / flag |
|---|---|
| Resume most recent session | `pi -c` (or `--continue`) |
| Browse & pick a past session | `pi -r`, or `/resume` in-session |
| Name the current session | `/name <label>` |
| Jump/branch to an earlier point | `/tree`, `/fork` |
| One-shot, no saved session | `pi -p "question"` (`--print`) |
| Export / share a session | `/export` (HTML/JSONL) · `/share` (private gist) |

Combined with the `ai-session` tmux helper from step 7, `pi -c` inside a session
means you can drop off your phone and pick up on your laptop mid-task. (omp has
the same session model via `omp --resume`.)

### First-run trust

The first time you launch pi in a project with its own `.pi/` settings or
skills, it asks whether to trust that directory (it could otherwise silently
change pi's config). `/trust` saves the decision to `~/.pi/agent/trust.json`;
`defaultProjectTrust` in global settings sets the fallback (`ask`/`always`/`never`).

### Sandboxed pi (ties into the security review)

pi has no built-in tool sandbox, so for untrusted repos its own docs recommend a
container. Their minimal image:

```dockerfile
FROM node:24-bookworm-slim
RUN apt-get update && apt-get install -y bash ca-certificates git ripgrep
RUN npm install -g @earendil-works/pi-coding-agent
WORKDIR /workspace
ENTRYPOINT ["pi"]
```

```bash
docker build -t pi-sandbox -f Dockerfile.pi .
docker run --rm -it -e LLAMA_BASE_URL -e LLAMA_API_KEY \
  --network host -v "$PWD:/workspace" pi-sandbox
```

`--network host` lets the container reach `127.0.0.1:8080`; mount only the repo
you're working on.

## 5c. pi or omp? Choosing your agent

The stack up to the model server is identical for both agents — the choice only
changes what drives it. Set it once (`./manage.sh` → *Choose agent*, or
`./setup-qwen38-pi.sh save-config AGENT=omp`) and every other step follows.

**[pi](https://pi.dev)** is the baseline this guide started with: deliberately
minimal, fast to start, easy to reason about. A handful of built-in tools, an
extension API, and the `/llama` router. If you want something small and
predictable, or you're debugging the stack itself, stay on pi.

**[oh-my-pi / omp](https://github.com/can1357/oh-my-pi)** is a coding-focused
fork of pi with, as the author puts it, "the IDE wired in." Concretely it adds
~32 built-in tools, **LSP** integration on every write (workspace renames,
refactors, diagnostics), a real **debugger** (lldb/dlv/debugpy via DAP),
**hashline** content-hash edits (cheaper, corruption-resistant rewrites),
worktree-isolated **subagents** with typed JSON output, a persistent Python/Bun
kernel, headless browser + web search, and cross-session memory. Most
relevant here: omp ships a set of **local-model reliability extensions**
(arg-repair, output-parser, syntax-guard, read-before-edit, quality-monitor)
that specifically catch the ways a local 27B model trips up — malformed tool
arguments, tool calls emitted as fenced prose, edits to unread files. On a
local Qwen that difference is felt, not cosmetic.

The trade: omp is heavier (runs on the Bun runtime, more moving parts) and
newer. My recommendation for *this* box — a 128GB machine whose whole purpose
is serious local agentic coding — is **omp**, with pi kept one `save-config`
away as the reliable fallback. Both are covered below and both are wired to the
exact same API-key-protected `llama-server`.

## 5d. omp: comprehensive local-Qwen configuration

Everything omp-specific the `omp` step sets up, and the tuning that makes a
local model behave. Config lives in `~/.omp/agent/` (`config.yml`, `models.yml`,
`rules/`, `skills/`); omp also auto-imports existing `.claude/`, `.cursor/`,
`.windsurf/`, `.github/copilot/` config, and reads `AGENTS.md` like pi does.

### Install

`./setup-qwen38-pi.sh omp` installs the Bun runtime if needed, then omp via its
official installer (`curl -fsSL https://omp.sh/install | sh`), and writes the
two config files below plus the required environment exports to `~/.bashrc`.
Verify with `omp --version`.

### models.yml — point omp at the local server

```yaml
providers:
  llamacpp:
    baseUrl: http://127.0.0.1:8080/v1
    api: openai-completions          # llama.cpp speaks the chat-completions API
    apiKey: LLAMA_API_KEY            # omp reads this ENV VAR NAME, not a literal
    authHeader: true                 # send it as Authorization: Bearer
    discovery:
      type: llama.cpp                # auto-surface whatever the router has loaded
    models:
      - id: Qwen3.8-27B              # explicit entry => --model llamacpp/Qwen3.8-27B works day one
        name: Qwen 3.8 27B (local)
        reasoning: true
        input: [text, image]
        contextWindow: 131072
        maxTokens: 32768
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
        compat:
          supportsStore: false       # llama.cpp has no server-side response store
          supportsDeveloperRole: false
```

Note the key difference from pi's `models.json`: omp resolves `apiKey` by
**environment-variable name** — `apiKey: LLAMA_API_KEY` means "use the value of
`$LLAMA_API_KEY`" (pi used `$LLAMA_API_KEY` interpolation). `authHeader: true`
plus our API-key-protected server is why this isn't `auth: none`.

### config.yml — the tuning that matters for a local model

```yaml
setupVersion: 1
symbolPreset: nerd
modelRoles:
  default: llamacpp/Qwen3.8-27B      # bare `omp` uses the local model, no --model flag
compaction:
  supersedeReads: false              # <- keep conversation history append-only
  dropUseless: false                 # <-
memory:
  backend: "off"
```

Those two `compaction` flags are the single most important local-model setting,
and they tie directly back to the server: we run `llama-server` with **one slot**
(`-np 1`) and `--cache-reuse 256`, so the model keeps a **prompt cache** of the
conversation prefix and only processes new tokens each turn. That cache survives
only if the prefix never changes. Default compaction rewrites interior messages
to save tokens — which silently invalidates the cache and makes every turn
reprocess the whole context. Setting `supersedeReads`/`dropUseless` to `false`
keeps history strictly append-only, so the cache stays warm and turns stay fast.
The server side of the same bargain is already in the launcher:
`--chat-template-kwargs '{"...","preserve_thinking":true}'` keeps `<think>`
blocks in place so they don't shift the prefix either.

### Environment (written to ~/.bashrc)

```bash
export LLAMA_BASE_URL=http://127.0.0.1:8080
export LLAMA_CPP_BASE_URL=http://127.0.0.1:8080   # omp's built-in llama.cpp provider var
export LLAMA_API_KEY=$(cat ~/.config/local-ai/llama.key)
export PI_NO_TITLE=1          # stop between-turn title-gen calls from evicting the KV slot
export OMPX_PARSER_ACTIVE=1   # force the output-parser repair path (local models need it)
```

`PI_NO_TITLE=1` is subtle but matters: by default the agent makes a small extra
call to generate a session title, which — with a single slot — evicts your warm
prompt cache. Turning it off keeps the slot yours. `OMPX_PARSER_ACTIVE=1` turns
on omp's active repair for models that occasionally emit tool calls as fenced
text instead of structured calls; Qwen at Q4 does this sometimes.

### LSP servers (optional but recommended)

omp wires LSP into every edit, so installing language servers for what you work
in unlocks rename/refactor/diagnostics:

```bash
./setup-qwen38-pi.sh omp-lsp
# installs: bash-language-server typescript-language-server python-lsp-server
#           gopls rust-analyzer clang   (skip/add per your languages)
```

### Roles, subagents, and going further

omp routes different jobs to different models via `modelRoles` in `config.yml` —
`default`, `smol` (quick ops), `slow` (deep reasoning), `plan`, `vision`,
`commit`. On an all-local box you can point them all at `llamacpp/Qwen3.8-27B`,
or — because 128GB fits more than one model — load a small fast GGUF in the
router and assign it to `smol`/`commit` so trivial calls don't wait on the 27B:

```yaml
modelRoles:
  default: llamacpp/Qwen3.8-27B
  smol:    llamacpp/Qwen3-4B        # if you've dropped a small GGUF in ~/llm/models
  commit:  llamacpp/Qwen3-4B
```

Subagents run with workspace isolation and typed JSON output, so `/review` can
fan out several review passes in parallel — genuinely useful when the underlying
model is slower than a frontier API. Reference config this is modeled on:
[havfo/omp-config](https://github.com/havfo/omp-config) (a real local-Qwen omp
setup) and omp's own [models](https://github.com/can1357/oh-my-pi/blob/main/docs/models.md)
/ [providers](https://github.com/can1357/oh-my-pi/blob/main/docs/providers.md) docs.

## 6. Verify

```bash
./setup-qwen38-pi.sh status      # service + /v1/models + a chat round-trip
./setup-qwen38-pi.sh bench       # llama-bench pp512/tg128 numbers for your box
```

Then a real smoke test — in an empty directory, run your agent (`pi` or `omp`)
and ask:

> Create hello.py that prints the first 10 Fibonacci numbers, run it, and show me the output.

You should see it think briefly, write the file with a tool call, execute it,
and report the output. If it instead prints tool-call JSON as plain text,
that's the template trap — check `--jinja` and update llama.cpp.

## 7. Drive it from your phone, iPad, and laptops

The trick is that pi never runs *on* your phone — it keeps running on the
Framework Desktop inside a tmux session, and every device is just a window
into it. Close the laptop, walk away, reattach from the couch on the iPhone:
the agent kept working the whole time. Set it up with:

```bash
./setup-qwen38-pi.sh remote
```

That one command installs `openssh`, `mosh`, `tmux`, `avahi`, and `ufw`, then
wires up four things. First, sshd with a hardening drop-in
(`/etc/ssh/sshd_config.d/20-local-ai-lan.conf`): no root login, logins allowed
for your user only, password auth left on *temporarily* so you can bootstrap
keys from each device. Second, mDNS via avahi, so every Apple device and
laptop on your wifi can reach the machine as `genion.local` — no IP addresses
to remember (still worth adding a DHCP reservation for it in your router).
Third, a firewall scoped to your home network: it auto-detects your LAN subnet
and allows *only* SSH (22/tcp), mosh (60000–61000/udp), and mDNS (5353/udp)
from that subnet, with everything else inbound denied — so even if your router
misbehaves, nothing here answers to the internet. **Do not port-forward 22 on
your router**; nothing in this setup should be internet-facing. Fourth, an
`ai-session` helper in `/usr/local/bin` (with `pi-session` kept as an alias),
plus a phone-friendly `~/.tmux.conf` (only if you don't already have one).

### The workflow

```bash
# from a laptop
ssh -t lyonwj@genion.local ai-session ~/github/my-project
mosh lyonwj@genion.local -- ai-session ~/github/my-project   # better on wifi/moving around

# from the phone, after connecting: 
ai-session ~/github/my-project
```

`ai-session <dir>` attaches to the tmux session for that project, creating it
(and launching your selected agent — `pi` or `omp` — in it) on first use.
Detach with `Ctrl-b` then `d` — the agent keeps running. Run `ai-session` with
no arguments to list what's live. Several devices can attach to the same
session simultaneously and mirror the same screen — handy for kicking off a
task from the desk and watching it finish from the phone.

### Device setup, once per device

Laptops: `ssh-copy-id lyonwj@genion.local`, done. iPhone/iPad: install
[Blink Shell](https://blink.sh) (best mosh support — the session survives iOS
suspending the app) or [Termius](https://termius.com); generate a key in the
app, connect once with your password, and append the app's public key to
`~/.ssh/authorized_keys`. When every device has a key that works:

```bash
./setup-qwen38-pi.sh ssh-harden   # refuses to run until at least one key is installed
```

which flips SSH to key-only. The llama.cpp API itself stays bound to
`127.0.0.1` through all of this — remote devices talk to pi over SSH, and pi
talks to the model over loopback. (If you ever want a laptop LLM client to hit
the API directly, tunnel it: `ssh -L 8080:127.0.0.1:8080 genion.local` — no
firewall changes needed.) If you later want access *away* from home, don't
open ports — put Tailscale or WireGuard on the box and keep this firewall
exactly as it is.

## Security model & hardening

An adversarial review of this setup turned up several things worth
understanding. The single most important one first:

**pi runs tools with no approval prompts, as your user.** pi's own docs are
blunt about it: *"Built-in tools can read files, write files, edit files, and
run shell commands with the permissions of the pi process,"* and *"prompt
injection from repository files, comments, documentation, context files, or
build output is expected local-agent risk and cannot be reliably prevented."*
Concretely: a `README`, a code comment, or build output in any repo pi touches
can carry instructions that pi may act on — and it will run them as `lyonwj`,
which on this box means access to your SSH keys, your files, and `sudo`. Making
the machine reachable from more devices doesn't create this risk, but it widens
who can kick off a session that hits it. Mitigations, strongest first:

- **Run the agent as a dedicated, sudo-less user** (e.g. `agent`) whose home
  holds only the repos you want it to touch. You still SSH in as yourself and
  `sudo -u agent -i` (or give that user its own key); a prompt-injection blast
  then can't read your keys or escalate. This is the highest-leverage change
  and the one I'd actually do.
- **Only point pi at repos you'd run `make` from without reading first.** Treat
  cloning a random repo and turning pi loose in it like running its build
  scripts — because that's the equivalent.
- **For anything untrusted, run pi in a container or VM** with only the
  workspace mounted, per pi's own guidance.

The script now also applies these (all shipped in the updated
`setup-qwen38-pi.sh`):

**llama-server is API-key protected.** It binds to `127.0.0.1`, but with
`CORS *` set, any web page open in a browser *on the desktop* could POST to
`http://127.0.0.1:8080` and use your model. The server now requires a key
(`--api-key-file`, so it never shows up in `ps`), generated at
`~/.config/local-ai/llama.key`. **This is the one change that affects your
current working setup**: pi needs the key in its environment, so add it once —

```bash
echo 'export LLAMA_API_KEY=$(cat ~/.config/local-ai/llama.key)' >> ~/.bashrc
```

— and re-run `./setup-qwen38-pi.sh service`. A `401` from pi means that export
is missing.

**The llama-server systemd unit is now sandboxed** — `NoNewPrivileges`,
`ProtectSystem=strict`, `ProtectHome=read-only`, `PrivateTmp`, and friends,
with `ReadWritePaths` narrowed to the models dir (so `/llama` downloads still
work). A malicious or malformed GGUF that trips a parser bug is then contained
to a read-only view of the system instead of running freely as your user.

**SSH hardening is now verified, not assumed.** `sshd` uses *first-match-wins*,
so a `PasswordAuthentication yes` sitting above the `Include` line in the main
`sshd_config` would silently defeat the drop-in — you'd think passwords were
off when they weren't. The script now validates with `sshd -t` before
reloading and confirms the *resolved* setting with `sshd -T` afterward, failing
loudly if it didn't take. `ssh-harden` refuses to claim success unless the
change actually stuck.

**Brute-force resistance during the bootstrap window.** Password auth is on
only until you run `ssh-harden` — a window where any device on your wifi
(including a compromised IoT gadget) can attempt logins. The firewall now uses
`ufw limit` on SSH (drops a source after ~6 attempts/30s), installs
**fail2ban** with a 4-strikes-per-10-min ban, and sets `MaxAuthTries 3`. None
of that substitutes for finishing the job: **run `ssh-harden` the same day.**

**IPv6 isn't left to chance.** The LAN allow-rules are IPv4, and IPv6 inbound
relies on ufw's default-deny — but only if ufw actually manages ip6tables. Many
home ISPs hand out a *globally routable* IPv6 address via SLAAC, so if
`IPV6=no` were set, `sshd` (which listens on `::`) could be exposed to the
internet. The script forces `IPV6=yes` in `/etc/default/ufw` and adds
`default deny routed`.

**mDNS is spoofable — verify the host key once.** `genion.local` is
unauthenticated; a hostile LAN device can impersonate it and harvest your
password on the *first* connect, before your SSH client has pinned a host key.
The `remote` step now prints the machine's host-key fingerprints; compare them
against what your client shows on first connection (and getting off password
auth quickly closes this too).

What's intentionally *not* covered: internet access from outside your home. The
answer there is a mesh VPN (Tailscale/WireGuard) on the box, **not** a
port-forward — leave this firewall exactly as it is.

## What to expect (honest numbers)

Measured/reported figures for Qwen 3.8 27B on Ryzen AI Max+ 395 machines:

| Setup | Generation |
|---|---|
| Q4, Vulkan, no MTP (baseline) | ~12 t/s |
| Q4, Vulkan, MTP draft 4 (AMD official, this guide's default) | **up to ~24.5 t/s** |
| Community-tuned forks (custom FP4 + aggressive/lossy speculation) | ~30-36 t/s |

Real-world agentic feel: coding-agent output (structured, repetitive) has high
MTP acceptance, so pi sessions sit near the top of the range; free-flowing
prose sits lower. Prompt processing is the bigger tax on a big first prompt —
a few hundred t/s means a huge repo dump takes a while — but llama-server's
prefix caching makes every *subsequent* turn in a pi session process only the
new tokens. Expect the fans; sustained generation pulls ~100W+ on the GPU.

Q8_0 roughly halves generation speed (memory-bandwidth-bound dense model);
with MTP it lands around the old Q4 baseline — a fair trade when you want
maximum quality overnight and don't mind the pace.

## Troubleshooting

**pi/omp reports `401` / unauthorized** — the server is API-key protected now;
`export LLAMA_API_KEY=$(cat ~/.config/local-ai/llama.key)` in the shell you run
the agent from (and add it to `~/.bashrc`). See the security section. For omp,
also confirm `models.yml` has `apiKey: LLAMA_API_KEY` and `authHeader: true`.

**`omp: command not found` after install** — the Bun bin dir isn't on PATH yet.
Open a new shell, or `export PATH="$HOME/.bun/bin:$HOME/.local/bin:$PATH"`.
`ai-session` already adds both.

**omp emits tool calls as plain text / mangles tool arguments** — expected
local-model roughness; make sure `export OMPX_PARSER_ACTIVE=1` is set (the `omp`
step adds it to `~/.bashrc`), which turns on omp's output-parser and arg-repair.

**Turns get slow again after a while (omp or pi)** — something is breaking the
prompt cache. Check the server still runs `-np 1 --cache-reuse 256`, keep omp's
`compaction.supersedeReads/dropUseless: false`, and make sure `PI_NO_TITLE=1` is
exported so title-generation isn't evicting the slot.

**Model load fails with `no CPU backend found`** (router runs, but every
model spawn exits with status 1, and the mmproj/CLIP load fails too) — the
`ggml-cpu` split package is missing; it's only an *optional* dep of `ggml` on
Arch, but llama.cpp requires it even for pure-Vulkan inference. Fix:
`sudo pacman -Syu ggml-cpu` (full `-Syu` keeps ggml/ggml-vulkan/llama-cpp on
matching builds), then restart the service.

**Tool calls come out as plain text / agent loops uselessly** — the template
trap: ensure `--jinja`, update `llama-cpp` (template fixes land frequently),
and prefer the unsloth GGUFs which embed the corrected template.

**Out-of-memory on model load** — check GTT: `./setup-qwen38-pi.sh check`.
Either lower `-c`, use the Q4 quant, or run `kernel-tweaks` + reboot. Remember
`free -h` won't show GTT usage; use `amdgpu_top` (`pacman -S amdgpu_top`).

**Slow first token on big prompts** — expected (prompt processing); keep pi
sessions going so the prefix cache works for you. Don't restart the server
between tasks.

**MTP metrics missing from logs / no speedup** — your build may predate MTP
or the quant is too low; verify with `journalctl --user -u llama-server | grep
-i draft` and check acceptance rate (healthy: 0.55-0.85).

**Vulkan device missing** — `vulkaninfo --summary`; make sure `vulkan-radeon`
is installed (not just amdvlk), and reboot after the first driver install.

**Everything slow after suspend** — known amdgpu quirk on some kernels;
restart the service, or reboot.

**`genion.local` doesn't resolve** — check `systemctl status avahi-daemon` on
the desktop; Apple devices and most Linux laptops speak mDNS natively, but
some Android/Windows clients don't — use the IP (set a DHCP reservation in
your router) or add the host manually in the SSH app.

**Locked out after enabling the firewall** — from the desktop's own
keyboard: `sudo ufw status numbered`, then re-add your subnet
(`sudo ufw allow from 192.168.x.0/24 to any port 22 proto tcp`) or re-run
`LAN_CIDR=<your-subnet> ./setup-qwen38-pi.sh remote`. This can happen if your
subnet changed (new router, VLANs) after setup.

**mosh connects then hangs** — the UDP range is blocked: re-run `remote` (or
allow `60000:61000/udp` from your subnet in ufw). Plain `ssh` still working
while mosh doesn't is the tell.

**Session gone when phone reconnects** — you likely ran `pi` directly over
SSH instead of inside `ai-session`; bare SSH processes die with the
connection. Always go through `ai-session` from remote devices.

## Going further

**A/B ROCm.** For this model's unusual hybrid architecture, some Strix Halo
users measure ROCm ahead of Vulkan (the opposite of the usual MoE result).
Arch makes the experiment cheap: `sudo pacman -S ggml-hip`, then
`llama-server --list-devices` and add `--device ROCm0` (or `Vulkan0`) to the
launcher, and compare with `./setup-qwen38-pi.sh bench`. Keep whichever wins
this month.

**Chase the last 10 t/s.** The [q38rocm](https://github.com/julianmb/q38rocm)
project hits ~36 t/s with a custom FP4 format, KV-cache tricks and relaxed
(lossy!) speculation on a pinned llama.cpp fork — fun, but you leave
"boring and reproducible" behind.

**More models in the same rig.** Drop any GGUF into `~/llm/models/<name>/`
and it appears in pi's `/llama` — e.g. gpt-oss-120b (~48 t/s on this hardware,
after `kernel-tweaks`) as a second opinion, or a small draft-friendly model
for other spec-decoding experiments.

**AMD Lemonade / LM Studio.** AMD's Lemonade server and LM Studio both wrap
llama.cpp with GUIs and are fine alternatives; this guide stays with plain
`llama-server` because it's scriptable, systemd-friendly, and exactly what pi
expects.

## Sources

Qwen 3.8 27B: [official model card](https://huggingface.co/Qwen/Qwen3.8-27B) ·
[unsloth GGUFs](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) ·
[unsloth run guide](https://unsloth.ai/docs/models/qwen3.8) ·
[MTP-in-GGUF confirmation](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/discussions/12) ·
[GGUF sizes & template trap](https://dev.to/purpledoubled/run-qwen-38-27b-locally-real-gguf-sizes-the-kv-cache-trick-and-the-template-trap-114j)

Hardware & tuning: [AMD day-0 guide for Qwen 3.8 on Ryzen AI Max](https://www.amd.com/en/blogs/2026/run-qwen-3-8-27b-on-amd-ryzen-ai-max-and-radeon-graphics-cards-day-0.html) ·
[Framework: using the Desktop for local AI](https://frame.work/blog/using-a-framework-desktop-for-local-ai) ·
[Framework Strix Halo LLM setup guide](https://github.com/Gygeek/Framework-strix-halo-llm-setup) ·
[Strix Halo community guide](https://github.com/hogeheer499-commits/strix-halo-guide) ·
[q38rocm tuned recipe](https://github.com/julianmb/q38rocm) ·
[KyaniteLabs honest numbers](https://kyanitelabs.tech/blog/qwen-27b-strix-halo-one-week-local)

Remote access: [Arch Wiki: OpenSSH](https://wiki.archlinux.org/title/OpenSSH) ·
[Arch Wiki: UFW](https://wiki.archlinux.org/title/Uncomplicated_Firewall) ·
[Arch Wiki: Avahi](https://wiki.archlinux.org/title/Avahi) ·
[mosh](https://mosh.org) · [tmux](https://github.com/tmux/tmux/wiki) ·
[Blink Shell](https://blink.sh) · [Termius](https://termius.com)

oh-my-pi (omp): [repo](https://github.com/can1357/oh-my-pi) ·
[models.md](https://github.com/can1357/oh-my-pi/blob/main/docs/models.md) ·
[providers.md](https://github.com/can1357/oh-my-pi/blob/main/docs/providers.md) ·
[havfo/omp-config (local-Qwen reference)](https://github.com/havfo/omp-config) ·
[omp deep-dive](https://acchapm1.github.io/tutorials/Oh-My-Pi/omp-deep-dive) ·
[omp + llama.cpp walkthrough](https://sukhbinder.wordpress.com/2026/02/15/oh-my-pi-with-llamacpp/)

llama.cpp & pi: [llama-server docs](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) ·
[MTP support PR #22673](https://github.com/ggml-org/llama.cpp/pull/22673) ·
[MTP usage gist](https://gist.github.com/eeshansrivastava89/85797104af34181944bfd1360d69e8af) ·
[Arch llama-cpp package](https://archlinux.org/packages/extra/x86_64/llama-cpp/) ·
[pi + llama.cpp official guide](https://pi.dev/docs/latest/llama-cpp) ·
[pi with a local LLM walkthrough](https://mschygulla.github.io/posts/local-pi-coding-agent/) ·
[HF: local agents with llama.cpp](https://huggingface.co/docs/hub/agents-local) ·
[pi design notes](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/)
