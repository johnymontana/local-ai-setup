# Local AI for Omarchy

Your Framework Desktop. Your models. A terminal away.

A local coding workspace for a freshly installed [Omarchy](https://omarchy.org/)
system on the **Framework Desktop, Ryzen AI Max+ 395, 128 GiB**. Open a compact
keyboard-driven menu, keep an everyday model warm, and bring in larger models
when the work calls for them.

```text
local-ai
   └─ OMP coding agent
        └─ authenticated localhost llama.cpp router
             └─ one pinned model at a time · Mesa RADV / Vulkan
```

The experience follows Omarchy's terminal, theme, and personal-configuration
conventions. The Strix Halo memory and inference settings remain the same.

## Make yourself at home

Open an Omarchy terminal with **Super + Return** and update the system:

```bash
omarchy update
```

Reboot if requested, then clone and inspect this repository. Keep the checkout:
the installed command points back to it. Omarchy's updater handles its
snapshots and migrations. [Update guide](https://omarchy.org/manual/updates/).

```bash
mkdir -p ~/github
git clone https://github.com/johnymontana/local-ai-setup.git ~/github/local-ai-setup
cd ~/github/local-ai-setup
git rev-parse HEAD
less install.sh
less setup-qwen38-pi.sh
./install.sh
```

Run as your ordinary desktop user; the installer asks for `sudo` only for
system changes. It checks for pending updates, installs the runtime packages,
everyday model and pinned agent, enables the user service, and adds **Local AI**
and **Local AI Logs** to app search. If it requests a reboot, reboot and run `./install.sh`
again. Downloads resume. For repeatable deployments, use a
[reviewed commit](docs/reference.md#reproducible-downloads-and-installs).

After installation, open a new terminal:

```bash
local-ai status
local-ai smoke everyday
cd ~/github/your-project
local-ai-agent
```

Use `local-ai` to open the menu, or search for **Local AI** in Omarchy's app
launcher. `status` reads state; `smoke` intentionally loads a model and generates
a response. [The workstation guide](docs/omarchy.md) covers setup, desktop
integration, updates, backups, and recovery.

## A small model team

| Model | Best place to start | Locked download |
|---|---|---:|
| **Everyday** · Qwen 3.8 27B | Implementation, tests, shell work, and vision | ~18.5 GiB |
| **Coder** · Qwen3-Coder-Next | Repository exploration, tools, and debugging | ~45.1 GiB |
| **Senior** · Qwen3.5-122B-A10B | Planning, difficult bugs, and review | ~69.5 GiB |

The installer starts with Everyday. Allow **24 GiB free** for its default Q4
artifacts and the 5 GiB reserve. All three tiers need about **138 GiB free**;
using Everyday Q8 raises that to about **149 GiB**. Every artifact is pinned by
revision, size, and SHA-256 in [models.lock](models.lock). Senior uses an optional
community Unsloth quant.

Add a specialist when needed:

```bash
local-ai model coder
local-ai plan
local-ai apply
local-ai smoke coder
cd ~/github/your-project
omp-coder
```

Use `senior` in the same workflow for the larger reviewer. `omp-everyday`,
`omp-coder`, and `omp-senior` select a phase explicitly; launchers exist for
complete installed tiers. The default sticky routing keeps one model warm and
one request in flight, leaving room for the desktop. Omarchy's own `omp` and
`pi` commands stay available; use this project's launchers for its pinned stack.

## Same hardware, considered defaults

Keep the BIOS UMA framebuffer at its small/default **512 MiB** and **IOMMU
enabled**. Start with stock GTT. Vulkan offload, per-model context, MTP,
load modes, and the single-resident-model limit retain the existing Framework
Desktop tuning. The optional **115 GiB GTT** setting is for measured needs;
Senior can use mixed CPU/GPU loading at the stock limit.

These are configuration defaults, not a claim of new hardware benchmark
results. Run the [on-machine checks](docs/omarchy.md#verify-on-the-workstation)
after installation and driver updates.

## Keep it yours

Configuration lives in `~/.config/local-ai`, models in `~/llm/models`, and the
router runs as your user. The menu follows your terminal's colors and uses
Omarchy's palette when available. Personal settings and desktop integration
follow [Omarchy's dotfile conventions](https://omarchy.org/manual/dotfiles/).

Inference stays local. Coding agents can still read files, run commands, and
use the network with your account's permissions; read the
[security boundaries](docs/reference.md#security-boundaries) before using
untrusted repositories.

- [Omarchy workstation guide](docs/omarchy.md) — install, daily use, updates, recovery.
- [Full reference](docs/reference.md) — models, tuning, commands, remote access, security.
- [Contributor checks](docs/reference.md#contributor-checks) — portable tests and opt-in hardware checks.
- [Performance implementation record](docs/performance-dx-plan.md) — rationale and acceptance layers.
