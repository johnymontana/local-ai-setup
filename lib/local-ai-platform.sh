#!/usr/bin/env bash
# Omarchy integration shared by the engine and its read-only status surfaces.
# Importing this file never starts Omarchy tools or changes the host.

local_ai_os_release_value() {
  local key="$1" file="${LOCAL_AI_OS_RELEASE:-/etc/os-release}"
  [[ -r "$file" ]] || return 0
  # os-release is data. Do not source shell statements from it.
  awk -v key="$key" '
    index($0, key "=") == 1 {
      value=substr($0, length(key)+2)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value=substr(value,2,length(value)-2)
      print value
      exit
    }
  ' "$file"
}

local_ai_is_omarchy() {
  # A stray command or checkout on another OS is not an Omarchy installation.
  case "$(local_ai_os_release_value ID)" in
    arch|omarchy) ;;
    *) return 1 ;;
  esac
  # Omarchy keeps Arch's os-release identity. Detect installed command entry
  # points or its version file, including the older per-user installation.
  command -v omarchy >/dev/null 2>&1 ||
    command -v omarchy-update >/dev/null 2>&1 ||
    [[ -r "${OMARCHY_PATH:-$HOME/.local/share/omarchy}/version" ]] ||
    [[ -r /usr/share/omarchy/version ]]
}

local_ai_platform_name() {
  if local_ai_is_omarchy; then
    printf '%s\n' 'Omarchy Linux (Arch base)'
  else
    local name
    name="$(local_ai_os_release_value PRETTY_NAME)"
    printf '%s\n' "${name:-$(uname -s)}"
  fi
}

local_ai_omarchy_update_command() {
  if command -v omarchy >/dev/null 2>&1; then
    printf '%s\n' 'omarchy update'
  elif command -v omarchy-update >/dev/null 2>&1; then
    printf '%s\n' 'omarchy-update'
  else
    printf '%s\n' 'Update > Omarchy in the Omarchy menu (Super + Space)'
  fi
}

local_ai_require_omarchy() {
  [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
    warn "This setup targets Omarchy Linux on the x86_64 Framework Desktop."
    return 1
  }
  case "$(local_ai_os_release_value ID)" in
    arch|omarchy) ;;
    *) warn "An Arch-based Omarchy installation is required (detected: $(local_ai_platform_name))."; return 1 ;;
  esac
  local_ai_is_omarchy || {
    warn "Omarchy was not detected. Complete the Omarchy installation and open an Omarchy terminal first."
    return 1
  }
  command -v pacman >/dev/null 2>&1 || { warn "pacman is missing from this Omarchy installation."; return 1; }
  [[ $EUID -ne 0 ]] || { warn "Run as your normal Omarchy user; sudo is used where needed."; return 1; }
}

local_ai_install_packages() {
  local_ai_require_omarchy || return 1
  local pending rc=0
  # Use the existing synchronized databases. Only Omarchy's update workflow
  # may refresh them and upgrade the system: it also handles snapshots and
  # migrations. Reject a known partial upgrade before any package mutation.
  pending="$(LC_ALL=C pacman -Qu 2>&1)" || rc=$?
  if (( rc != 0 )) && { (( rc != 1 )) || [[ -n "$pending" ]]; }; then
    printf '%s\n' "$pending" >&2
    warn "Could not inspect package updates. Run '$(local_ai_omarchy_update_command)', then retry."
    return 1
  fi
  if [[ -n "$pending" ]]; then
    printf '%s\n' "$pending" >&2
    warn "Pending system updates must be completed with '$(local_ai_omarchy_update_command)' before installing local AI packages. Reboot if requested, then retry."
    return 1
  fi
  # Validate the entire set against the selected Omarchy channel before sudo.
  # Never add repositories or fall back to an unreviewed source build/AUR.
  if ! pacman -Si -- "$@" >/dev/null; then
    warn "A required package is unavailable in your configured repositories. Run '$(local_ai_omarchy_update_command)', then retry on the same channel."
    return 1
  fi
  if ! sudo pacman -S --needed --noconfirm -- "$@"; then
    warn "Package installation failed. Complete '$(local_ai_omarchy_update_command)' and retry; keep Omarchy's configured repositories and channel."
    return 1
  fi
}

local_ai_require_boot_rebuild() {
  command -v limine-mkinitcpio >/dev/null 2>&1 || {
    warn "Omarchy's limine-mkinitcpio is required before changing TTM memory. Restore the stock Omarchy boot tooling before retrying."
    return 1
  }
}

local_ai_rebuild_boot_images() {
  # Omarchy uses Limine UKIs; mkinitcpio -P may do nothing when there are no
  # traditional presets. This also refreshes Limine entries and signing via
  # the installed Omarchy hooks, without editing bootloader configuration.
  local_ai_require_boot_rebuild || return 1
  sudo limine-mkinitcpio
}
