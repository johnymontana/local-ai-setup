# The visual workshop

[Start here](../../README.md) · [Workstation guide](../omarchy.md) · [Full reference](../reference.md)

The docs use an original visual treatment inspired by
[Omarchy’s Everforest theme](https://omarchy.org/manual/themes/): charcoal
surfaces, warm type, sage and teal accents, square borders, and terminal-like
spacing. These assets belong to this independent setup project; they are not
official Omarchy branding.

## Diagrams

The seven SVGs are editable source files. They contain their own colors, text,
accessible titles and descriptions, and vector shapes. They load without
JavaScript, remote fonts, or an image service. Technical facts also remain in
the surrounding Markdown so the docs work without images.

| Asset | Explains |
|---|---|
| [Hero](hero.svg) | The project and target workstation |
| [Model team](model-team.svg) | Default and optional tiers; download sizes versus residency |
| [Runtime map](runtime-map.svg) | Agent, loopback authentication, router, and GPU offload |
| [Install flow](install-flow.svg) | Native updates, the reboot gate, installation, and first checks |
| [Configuration map](config-map.svg) | System-owned defaults and the user’s working files |
| [Verification layers](verification-layers.svg) | Offline evidence and on-machine checks |
| [Herdr workspaces](herdr-workspaces.svg) | Persistent role panes, explicit delegation, and the shared inference slot |

Keep diagram labels aligned with the source and `models.lock` when behavior
changes. The download figures describe disk artifacts, not RAM use or measured
performance. View SVGs at both full size and a typical README width after edits.

## Terminal screenshots

The menu and plan PNGs are browser-rendered captures of **real CLI output** collected through
a pseudo-terminal. The commands run in an empty temporary home with no models
or agents installed. The fixture reports a stopped service and blocks API
probes. It never installs packages, starts services, downloads models, or uses
your live agent configuration.

| Screenshot | Command and state | Text equivalent |
|---|---|---|
| [The menu](screenshots/local-ai-menu.png) | `./local-ai`, plain menu before installation | [Transcript](screenshots/local-ai-menu.txt) |
| [Preview changes](screenshots/local-ai-plan.png) | `./local-ai plan`, showing unmet installation gates | [Transcript](screenshots/local-ai-plan.txt) |

These illustrate the interface, not a running Omarchy desktop or a hardware
validation result. The renderer adds an Everforest-colored terminal frame and
normalizes temporary home/check-out paths to `~`. The installed menu uses the
user’s active terminal palette; Omarchy installations with `gum` normally show
the interactive chooser instead of this plain fallback.

To regenerate, use Python 3, Bash, jq, Node.js, and a development installation
of [Playwright](https://playwright.dev/docs/intro) with Chromium. Keep that tooling
outside the runtime stack; users do not need it to install Local AI. From the
repository root, with `playwright` available to Node’s module resolver:

```bash
node docs/visuals/render-screenshots.cjs
```

`PYTHON` may select a Python executable; `LOCAL_AI_DOCS_BROWSER` may select an
existing Chromium executable. The script captures the current
commands, renders both PNGs at double resolution, and updates the plain-text
transcripts. Review the images and text together before committing them.

Capture sources: [PTY fixture](../visuals/capture-terminal.py) ·
[Terminal renderer](../visuals/render-screenshots.cjs).

## Native Herdr preview

![Native Herdr 0.9.0 in the isolated golf workspace fixture.](screenshots/herdr-golf-workspace.png)

The [golf workspace capture](screenshots/herdr-golf-workspace.png) shows the
real Herdr **0.9.0 macOS** terminal UI. The repository's workspace helper creates
coding and golf profiles in a temporary home using `--no-agent --no-attach`.
The fixture shortens the two display labels, prints sample text in Physics
and Course, and focuses Simulation. The empty agent list is intentional.
[Plain-text terminal view](screenshots/herdr-golf-workspace.txt).

This uses a real native Herdr server and client, with update/manifest network
checks disabled. It starts no model, coding agent, game, or project build.
It does not show an Omarchy desktop or establish Framework hardware behavior.
`pyte` emulates the terminal screen, and the browser renders those captured
cells with the Everforest palette and an explanatory frame. The fixture's
server is stopped and its temporary home removed after capture.

Use a reviewed native Herdr 0.9.0 executable, Python 3 with `pyte==0.8.2`, and
the same Node/Playwright browser setup as the CLI screenshots. No runtime user
needs these development dependencies. The capture never downloads Herdr:

```bash
PYTHON=/path/to/documentation-venv/bin/python \
  node docs/visuals/render-herdr-screenshot.cjs /absolute/path/to/reviewed/herdr
```

`LOCAL_AI_DOCS_HERDR` can supply the executable instead of the positional
argument. `LOCAL_AI_DOCS_BROWSER` selects an existing Chromium executable.
Capture sources: [native PTY fixture](../visuals/capture-herdr.py) ·
[cell renderer](../visuals/render-herdr-screenshot.cjs).
