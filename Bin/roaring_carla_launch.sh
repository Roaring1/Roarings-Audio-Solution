#!/usr/bin/env bash
set -euo pipefail

# Launch Carla's saved Roaring project. The DSP engine runs headless by default;
# set carla_mode=patchbay for the interactive editor.
CARLA_MODE_FILE="$HOME/.config/roaring/carla_mode"
CARLA_MODE="headless"
if [[ -r "$CARLA_MODE_FILE" ]]; then
  IFS= read -r CARLA_MODE < "$CARLA_MODE_FILE" || true
fi

# Inspect real process command lines instead of using pgrep -f. A service
# launcher shell can contain Carla's path in its own arguments and must not
# be mistaken for the engine. Exclude this process and every ancestor.
carla_pids() {
  local proc_root proc_dir pid current parent cmd ancestors_file
  proc_root="$(printenv ROARING_CARLA_PROC_ROOT 2>/dev/null || true)"
  [[ -n "$proc_root" ]] || proc_root="/proc"
  ancestors_file="$(mktemp)" || return 1

  current=$$
  while [[ "$current" =~ ^[0-9]+$ ]] && (( current > 1 )); do
    printf '%s\n' "$current" >> "$ancestors_file"
    [[ -r "$proc_root/$current/status" ]] || break
    parent="$(awk '/^PPid:/{print $2}' "$proc_root/$current/status" 2>/dev/null || true)"
    [[ "$parent" =~ ^[0-9]+$ ]] || break
    current="$parent"
  done

  for proc_dir in "$proc_root"/[0-9]*; do
    [[ -r "$proc_dir/cmdline" ]] || continue
    pid="$(basename "$proc_dir")"
    grep -qx "$pid" "$ancestors_file" && continue
    cmd="$(tr '\0' ' ' < "$proc_dir/cmdline" 2>/dev/null || true)"
    case "$cmd" in
      /usr/bin/python3\ /app/share/carla/carla\ *|/usr/bin/python3.13\ /app/share/carla/carla\ *|/usr/bin/python3.12\ /app/share/carla/carla\ *)
        printf '%s\n' "$pid"
        ;;
    esac
  done
  rm -f "$ancestors_file"
}

carla_already_running() {
  pids="$(carla_pids)"
  [[ -n "$pids" ]]
}

if carla_already_running; then
  echo "carla_launch: Carla already running - skipping new instance." >&2
  exit 0
fi

if ! command -v flatpak >/dev/null 2>&1; then
  echo "ERROR: flatpak not found; cannot launch Carla" >&2
  exit 1
fi
if ! flatpak info studio.kx.carla >/dev/null 2>&1; then
  echo "ERROR: Flatpak studio.kx.carla is not installed" >&2
  exit 1
fi

if [[ "${ROARING_CARLA_GUI:-0}" == "1" || "$CARLA_MODE" == "patchbay" ]]; then
  exec flatpak run studio.kx.carla "$@"
fi

if [[ "$CARLA_MODE" != "headless" && "$CARLA_MODE" != "rack" ]]; then
  echo "carla_launch: unknown mode '$CARLA_MODE'; using interactive patchbay" >&2
  exec flatpak run studio.kx.carla "$@"
fi

exec flatpak run studio.kx.carla --no-gui "$@"
