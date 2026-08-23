# Local agentic coding on a Framework Desktop: Qwen 3.8 27B + pi on Arch Linux

A tutorial and repeatable setup for running a fully local coding agent on the
Framework Desktop (AMD Ryzen AI Max+ 395 "Strix Halo", 128GB unified RAM):
[Qwen 3.8 27B](https://huggingface.co/Qwen/Qwen3.8-27B) served by
[llama.cpp](https://github.com/ggml-org/llama.cpp) over Vulkan, driven by the
[pi coding agent](https://pi.dev). No cloud, no API keys, no telemetry — your
code never leaves the machine.

**TL;DR**

```bash
chmod +x setup-qwen38-pi.sh
./setup-qwen38-pi.sh all        # install packages, download model, start server, install pi
./setup-qwen38-pi.sh status     # smoke-test the API
cd ~/some-project && pi         # then: /llama -> load model, /model -> select, go
./setup-qwen38-pi.sh remote     # optional: drive pi from your phone/iPad/laptops (LAN-only SSH)
```

Everything the script does is explained below, and every step can be run (and
re-run — it's idempotent) individually.

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

## 5. The agent

```bash
curl -fsSL https://pi.dev/install.sh | sh
export LLAMA_BASE_URL=http://127.0.0.1:8080    # put in ~/.bashrc; or use /login llama.cpp
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

If you prefer pinning a provider in config instead of the router flow, the
equivalent `~/.pi/agent/models.json` is:

```json
{
  "providers": {
    "local-llamacpp": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "api": "openai-completions",
      "apiKey": "none",
      "models": [
        { "id": "Qwen3.8-27B", "name": "Qwen 3.8 27B (local)",
          "reasoning": true, "input": ["text", "image"],
          "contextWindow": 131072, "maxTokens": 32768 }
      ]
    }
  }
}
```

## 6. Verify

```bash
./setup-qwen38-pi.sh status      # service + /v1/models + a chat round-trip
./setup-qwen38-pi.sh bench       # llama-bench pp512/tg128 numbers for your box
```

Then a real smoke test — in an empty directory, run `pi` and ask:

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
your router**; nothing in this setup should be internet-facing. Fourth, a
`pi-session` helper in `/usr/local/bin` (plus a phone-friendly `~/.tmux.conf`
with mouse/touch support, only if you don't already have one).

### The workflow

```bash
# from a laptop
ssh -t lyonwj@genion.local pi-session ~/github/my-project
mosh lyonwj@genion.local -- pi-session ~/github/my-project   # better on wifi/moving around

# from the phone, after connecting: 
pi-session ~/github/my-project
```

`pi-session <dir>` attaches to the tmux session for that project, creating it
(and launching pi in it) on first use. Detach with `Ctrl-b` then `d` — pi
keeps running. Run `pi-session` with no arguments to list what's live. Several
devices can attach to the same session simultaneously and mirror the same
screen — handy for kicking off a task from the desk and watching it finish
from the phone.

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
SSH instead of inside `pi-session`; bare SSH processes die with the
connection. Always go through `pi-session` from remote devices.

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

llama.cpp & pi: [llama-server docs](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) ·
[MTP support PR #22673](https://github.com/ggml-org/llama.cpp/pull/22673) ·
[MTP usage gist](https://gist.github.com/eeshansrivastava89/85797104af34181944bfd1360d69e8af) ·
[Arch llama-cpp package](https://archlinux.org/packages/extra/x86_64/llama-cpp/) ·
[pi + llama.cpp official guide](https://pi.dev/docs/latest/llama-cpp) ·
[pi with a local LLM walkthrough](https://mschygulla.github.io/posts/local-pi-coding-agent/) ·
[HF: local agents with llama.cpp](https://huggingface.co/docs/hub/agents-local) ·
[pi design notes](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/)
