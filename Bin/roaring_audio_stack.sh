#!/usr/bin/env bash
set -euo pipefail

# 9/1/2026-6
# Summary: Ensures vm_game/vm_chat/vm_music virtual sinks ALWAYS exist,
#          and ensures loopbacks (vm_*.monitor -> Astro target) without unload thrash.
#          Also supports toggling Astro target (CHAT <-> GAME) via config file.

CONF="$HOME/.config/roaring_mixer.conf"
LOG="$HOME/.cache/roaring-audio-stack.log"
mkdir -p "$HOME/.cache"

# trim log
if [[ -f "$LOG" ]] && [[ "$(wc -c < "$LOG")" -gt 1048576 ]]; then
  tail -n 5000 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi
exec >>"$LOG" 2>&1

DEDUP_INTERVAL_SEC=15

log() { echo "[stackd] $(date +%H:%M:%S) $*"; }
now_sec() { date +%s; }

if systemctl --user is-active -q roaring-audio-stackd.service 2>/dev/null; then
  log "stackd active; exiting to avoid duplicate loopback management."
  exit 0
fi

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

loopback_exists() {
  local src="$1" sink="$2"
  pactl list short modules 2>/dev/null \
    | awk '$2=="module-loopback" && $0 ~ ("source=" s) && $0 ~ ("sink=" k) {found=1} END{exit(found?0:1)}' \
      s="$src" k="$sink"
}

ensure_loopback() {
  local src="$1" sink="$2" latency="$3"
  if loopback_exists "$src" "$sink"; then
    return 0
  fi

  pactl load-module module-loopback source="$src" sink="$sink" latency_msec="$latency" >/dev/null 2>&1 || true
  if loopback_exists "$src" "$sink"; then
    log "created loopback: source=$src -> sink=$sink (latency=${latency}ms)"
  else
    log "FAILED create loopback: source=$src -> sink=$sink"
  fi
}

_last_dedupe_sec=0
dedupe_loopbacks_for_target() {
  local target="$1"
  local t; t="$(now_sec)"
  (( t - _last_dedupe_sec < DEDUP_INTERVAL_SEC )) && return 0
  _last_dedupe_sec="$t"

  local src
  for src in vm_game.monitor vm_chat.monitor vm_music.monitor; do
    mapfile -t ids < <(pactl list short modules 2>/dev/null | awk -v s="$src" -v k="$target" '
      $2=="module-loopback" && $0 ~ ("source=" s) && $0 ~ ("sink=" k) {print $1}
    ')
    if (( ${#ids[@]} > 1 )); then
      local keep="${ids[0]}"
      local id
      for id in "${ids[@]:1}"; do
        pactl unload-module "$id" >/dev/null 2>&1 || true
      done
      log "dedupe: kept $keep for $src -> $target (removed $(( ${#ids[@]} - 1 )))"
    fi
  done
}

ensure_loopbacks() {
  local target="$1"
  local latency="$2"

  # prerequisites
  sink_exists "$target" || return 0
  source_exists "vm_game.monitor"  || return 0
  source_exists "vm_chat.monitor"  || return 0
  source_exists "vm_music.monitor" || return 0

  ensure_loopback "vm_game.monitor"  "$target" "$latency"
  ensure_loopback "vm_chat.monitor"  "$target" "$latency"
  ensure_loopback "vm_music.monitor" "$target" "$latency"
  dedupe_loopbacks_for_target "$target"
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

    ensure_loopbacks "$ASTRO_TARGET" "$LATENCY_MSEC" || true
    sleep 1
  done
}

main
