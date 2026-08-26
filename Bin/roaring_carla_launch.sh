#!/usr/bin/env bash
set -euo pipefail

# roaring_carla_launch.sh
# Launches Carla (Flatpak) with the given project file.
# Called by roaring-carla-session.service.
#
# Guard: if a Carla instance is already running, exits 0 immediately so that
# systemd does not create a second instance (e.g. after a service restart when
# Carla was started manually or survived a previous service run).
#
# Mode file: ~/.config/roaring/carla_mode
#   "patchbay" -> carla (full patchbay UI)
#   anything else / missing -> carla (same binary, rack is default in carxp)
#
# Carla is Flatpak-only (studio.kx.carla) -- pw-jack/carla-rack do not exist.

CARLA_MODE_FILE="$HOME/.config/roaring/carla_mode"

# ── Duplicate-instance guard ──────────────────────────────────────────────────
# This script is invoked with the .carxp path as $1, so its own process cmdline
# contains 'CarlaProject_Roaring' — we must exclude our PID so the script
# doesn't mistake itself for a running Carla instance.
#   Only $ matches   → Carla NOT running → proceed with launch.
#   $ + others match → real Carla alive  → exit 0, no duplicate.
# Match /app/share/carla/carla (real python3 process) not .carxp (also hits bwrap wrappers).
carla_already_running() {
  pgrep -f '/app/share/carla/carla' >/dev/null 2>&1 ||
    pgrep -f '/usr/share/carla/carla' >/dev/null 2>&1
}

if carla_already_running; then
  echo "carla_launch: Carla already running — skipping new instance." >&2
  exit 0
fi
# ─────────────────────────────────────────────────────────────────────────────

if ! command -v flatpak >/dev/null 2>&1; then
  echo "ERROR: flatpak not found; cannot launch Carla" >&2
  exit 1
fi

if ! flatpak info studio.kx.carla >/dev/null 2>&1; then
  echo "ERROR: Flatpak studio.kx.carla is not installed" >&2
  exit 1
fi

exec flatpak run studio.kx.carla "$@"
