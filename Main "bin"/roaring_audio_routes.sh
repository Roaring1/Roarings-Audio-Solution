#!/usr/bin/env bash
set -euo pipefail

# 9/1/2026-6
# Summary: Ensures EXACTLY 3 loopbacks exist:
#          vm_{game,chat,music}.monitor -> $ASTRO_TARGET
#          Removes duplicates/wrong-target loopbacks to prevent phase/3D audio.

CONF="$HOME/.config/roaring_mixer.conf"
LOG="$HOME/.cache/roaring-audio-routesd.log"
mkdir -p "$HOME/.cache"
exec >>"$LOG" 2>&1

log() { echo "[routesd] $(date +%H:%M:%S) $*"; }
wait_for_pactl() { until pactl info >/dev/null 2>&1; do sleep 0.2; done; }

sink_exists()   { pactl list short sinks   2>/dev/null | awk '{print $2}' | grep -qx "$1"; }
source_exists() { pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "$1"; }

load_conf() {
  ASTRO_TARGET="alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-chat"
  LATENCY_MSEC="12"
  [[ -f "$CONF" ]] && source "$CONF" || true
}

unload_all_vm_loopbacks() {
  pactl list short modules 2>/dev/null | awk '
    $2=="module-loopback" &&
    ($0 ~ /source=vm_game\.monitor/ || $0 ~ /source=vm_chat\.monitor/ || $0 ~ /source=vm_music\.monitor/)
    {print $1}
  ' | while read -r id; do
    [[ -n "${id:-}" ]] || continue
    pactl unload-module "$id" >/dev/null 2>&1 || true
  done
}

count_exact_loopbacks() {
  local sink="$1"
  pactl list short modules 2>/dev/null | awk -v k="$sink" '
    $2=="module-loopback" && $0 ~ ("sink=" k) && $0 ~ /source=vm_(game|chat|music)\.monitor/ {c++}
    END{ print c+0 }
  '
}

have_one() {
  local src="$1" sink="$2"
  local n
  n="$(pactl list short modules 2>/dev/null | awk -v s="$src" -v k="$sink" '
    $2=="module-loopback" && $0 ~ ("source=" s) && $0 ~ ("sink=" k) {c++}
    END{ print c+0 }
  ')"
  [[ "$n" -eq 1 ]]
}

ensure_exact_three() {
  load_conf

  # prerequisites: vm sinks + monitor sources + astro sink
  sink_exists "vm_game"  || return 0
  sink_exists "vm_chat"  || return 0
  sink_exists "vm_music" || return 0

  source_exists "vm_game.monitor"  || return 0
  source_exists "vm_chat.monitor"  || return 0
  source_exists "vm_music.monitor" || return 0

  sink_exists "$ASTRO_TARGET" || return 0

  # If we already have exactly one of each and total 3, do nothing.
  if have_one "vm_game.monitor"  "$ASTRO_TARGET" \
  && have_one "vm_chat.monitor"  "$ASTRO_TARGET" \
  && have_one "vm_music.monitor" "$ASTRO_TARGET" \
  && [[ "$(count_exact_loopbacks "$ASTRO_TARGET")" -eq 3 ]]; then
    return 0
  fi

  log "rebuild: target=$ASTRO_TARGET latency=${LATENCY_MSEC}ms"
  unload_all_vm_loopbacks

  pactl load-module module-loopback source="vm_game.monitor"  sink="$ASTRO_TARGET" latency_msec="$LATENCY_MSEC" >/dev/null 2>&1 || true
  pactl load-module module-loopback source="vm_chat.monitor"  sink="$ASTRO_TARGET" latency_msec="$LATENCY_MSEC" >/dev/null 2>&1 || true
  pactl load-module module-loopback source="vm_music.monitor" sink="$ASTRO_TARGET" latency_msec="$LATENCY_MSEC" >/dev/null 2>&1 || true

  if [[ "$(count_exact_loopbacks "$ASTRO_TARGET")" -eq 3 ]]; then
    log "ok"
  else
    log "FAILED to enforce exact three loopbacks (count=$(count_exact_loopbacks "$ASTRO_TARGET"))"
  fi
}

main() {
  log "starting"
  while true; do
    wait_for_pactl
    ensure_exact_three || true
    sleep 2
  done
}

main
