#!/usr/bin/env bash
set -euo pipefail

# 9/1/2026-6
# Summary: Ensures vm_game/vm_chat/vm_music virtual sinks ALWAYS exist,
#          and enforces EXACTLY 3 loopbacks (vm_*.monitor -> Astro target).
#          Also supports toggling Astro target (CHAT <-> GAME) via config file.

CONF="$HOME/.config/roaring_mixer.conf"
LOG="$HOME/.cache/roaring-audio-stackd.log"
mkdir -p "$HOME/.cache"

# trim log
if [[ -f "$LOG" ]] && [[ "$(wc -c < "$LOG")" -gt 1048576 ]]; then
  tail -n 5000 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi
exec >>"$LOG" 2>&1

log() { echo "[stackd] $(date +%H:%M:%S) $*"; }

SINK_GAME="vm_game"
SINK_CHAT="vm_chat"
SINK_MUSIC="vm_music"

DESC_GAME="VM-GAME"
DESC_CHAT="VM-CHAT"
DESC_MUSIC="VM-MUSIC"

wait_for_pactl() { until pactl info >/dev/null 2>&1; do sleep 0.2; done; }

sink_exists()   { pactl list short sinks   2>/dev/null | awk '{print $2}' | grep -qx "$1"; }
source_exists() { pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "$1"; }

load_conf() {
  # defaults
  ASTRO_TARGET="alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-chat"
  LATENCY_MSEC="12"
  [[ -f "$CONF" ]] && source "$CONF" || true
}

ensure_vm_sink() {
  local sink_name="$1"
  local desc="$2"

  sink_exists "$sink_name" && return 0

  # Create sink + monitor source
  pactl load-module module-null-sink \
    sink_name="$sink_name" \
    sink_properties="device.description=${desc}" >/dev/null 2>&1 || true

  if sink_exists "$sink_name"; then
    log "created sink: $sink_name"
    return 0
  fi

  log "FAILED to create sink: $sink_name"
  return 1
}

unload_vm_loopbacks_all() {
  pactl list short modules 2>/dev/null | awk '
    $2=="module-loopback" &&
    ($0 ~ /source=vm_game\.monitor/ || $0 ~ /source=vm_chat\.monitor/ || $0 ~ /source=vm_music\.monitor/)
    {print $1}
  ' | while read -r id; do
    [[ -n "${id:-}" ]] || continue
    pactl unload-module "$id" >/dev/null 2>&1 || true
  done
}

count_loopbacks_to_target() {
  local target="$1"
  pactl list short modules 2>/dev/null | awk -v t="$target" '
    $2=="module-loopback" && $0 ~ ("sink=" t) &&
    ($0 ~ /source=vm_game\.monitor/ || $0 ~ /source=vm_chat\.monitor/ || $0 ~ /source=vm_music\.monitor/)
    {c++}
    END{print c+0}
  '
}

have_one_each() {
  local target="$1"

  pactl list short modules 2>/dev/null | grep -q "module-loopback source=vm_game.monitor sink=$target" || return 1
  pactl list short modules 2>/dev/null | grep -q "module-loopback source=vm_chat.monitor sink=$target" || return 1
  pactl list short modules 2>/dev/null | grep -q "module-loopback source=vm_music.monitor sink=$target" || return 1

  # also ensure there are exactly 3 vm loopbacks to that target
  local c
  c="$(count_loopbacks_to_target "$target")"
  [[ "$c" -eq 3 ]]
}

ensure_exact_three_loopbacks() {
  local target="$1"
  local latency="$2"

  # prerequisites
  sink_exists "$target" || return 0
  source_exists "vm_game.monitor"  || return 0
  source_exists "vm_chat.monitor"  || return 0
  source_exists "vm_music.monitor" || return 0

  if have_one_each "$target"; then
    return 0
  fi

  log "rebuild loopbacks: target=$target latency=${latency}ms"
  unload_vm_loopbacks_all

  pactl load-module module-loopback source="vm_game.monitor"  sink="$target" latency_msec="$latency" >/dev/null 2>&1 || true
  pactl load-module module-loopback source="vm_chat.monitor"  sink="$target" latency_msec="$latency" >/dev/null 2>&1 || true
  pactl load-module module-loopback source="vm_music.monitor" sink="$target" latency_msec="$latency" >/dev/null 2>&1 || true

  if have_one_each "$target"; then
    log "ok"
  else
    log "FAILED to enforce exact three loopbacks"
  fi
}

main() {
  log "starting"
  while true; do
    wait_for_pactl
    load_conf

    # VM sinks MUST exist (this is what makes them appear in UI)
    ensure_vm_sink "$SINK_GAME"  "$DESC_GAME"  || true
    ensure_vm_sink "$SINK_CHAT"  "$DESC_CHAT"  || true
    ensure_vm_sink "$SINK_MUSIC" "$DESC_MUSIC" || true

    ensure_exact_three_loopbacks "$ASTRO_TARGET" "$LATENCY_MSEC" || true
    sleep 1
  done
}

main
