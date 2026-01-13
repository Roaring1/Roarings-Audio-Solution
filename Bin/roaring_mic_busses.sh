#!/usr/bin/env bash
set -euo pipefail

# 10/1/2026-2
# Summary:
# - Ensures mic_b1 + mic_b2 virtual sinks exist (each sink creates a *.monitor source).
# - Creates remapped sources b1_mic and b2_mic so apps see them as normal microphones.
# - Sets default source to b2_mic only when needed (no constant re-setting).
# - Event-driven (pactl subscribe) instead of polling every 1s.
# - Flap-guard: if sinks keep getting removed repeatedly, exit non-zero so systemd can back off.

LOG="$HOME/.cache/roaring-mic-bussesd.log"
mkdir -p "$HOME/.cache"
exec >>"$LOG" 2>&1

log() { echo "[mic-bus] $(date +%H:%M:%S) $*"; }

wait_for_pactl() {
  local i=0
  until pactl info >/dev/null 2>&1; do
    ((i++)) || true
    if (( i > 300 )); then
      log "pactl not responding after ~60s."
      return 1
    fi
    sleep 0.2
  done
  return 0
}

sink_exists()   { pactl list short sinks   2>/dev/null | awk '{print $2}' | grep -qx "$1"; }
source_exists() { pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "$1"; }

get_default_source() {
  pactl info 2>/dev/null | awk -F': ' '/^Default Source:/{print $2}'
}

ensure_null_sink() {
  local name="$1" desc="$2"
  sink_exists "$name" && return 0

  pactl load-module module-null-sink \
    sink_name="$name" \
    rate=48000 channels=2 channel_map=front-left,front-right \
    sink_properties="device.description=$desc" >/dev/null 2>&1 || true

  sink_exists "$name" && log "created sink: $name ($desc)" || log "FAILED to create sink: $name"
}

ensure_remap_source() {
  local src_name="$1" desc="$2" master="$3"
  source_exists "$src_name" && return 0
  source_exists "$master" || return 0

  pactl load-module module-remap-source \
    source_name="$src_name" \
    master="$master" \
    remix=yes rate=48000 channels=2 channel_map=front-left,front-right \
    source_properties="device.description=$desc" >/dev/null 2>&1 || true

  source_exists "$src_name" && log "created source: $src_name ($desc) -> master=$master" || log "FAILED to create source: $src_name"
}

set_default_source_if_needed() {
  local wanted="$1"
  source_exists "$wanted" || return 0

  local cur
  cur="$(get_default_source || true)"
  [[ -z "${cur:-}" ]] && return 0

  if [[ "$cur" != "$wanted" ]]; then
    pactl set-default-source "$wanted" >/dev/null 2>&1 || true
    log "default source set: $cur -> $wanted"
  fi
}

ensure_all() {
  ensure_null_sink "mic_b1" "B1"
  ensure_null_sink "mic_b2" "B2"

  ensure_remap_source "b1_mic" "B1 Mic" "mic_b1.monitor"
  ensure_remap_source "b2_mic" "B2 Mic" "mic_b2.monitor"

  set_default_source_if_needed "b2_mic"
}

main() {
  log "starting"

  wait_for_pactl || exit 1
  ensure_all

  # flap guard: if we have to recreate sinks too many times quickly, something upstream is nuking modules.
  local flap_count=0
  local flap_window_start
  flap_window_start="$(date +%s)"

  while true; do
    # If pipewire-pulse restarts, this command will end; we loop back and resubscribe.
    pactl subscribe 2>/dev/null | while read -r line; do
      # only react to sink/source/server changes
      case "$line" in
        *"Event 'new' on sink"*|*"Event 'remove' on sink"*|*"Event 'new' on source"*|*"Event 'remove' on source"*|*"Event 'change' on server"*)
          ;;
        *) continue ;;
      esac

      # if our sinks vanished, we’re recreating — count it
      if ! sink_exists "mic_b1" || ! sink_exists "mic_b2"; then
        local now
        now="$(date +%s)"

        if (( now - flap_window_start > 60 )); then
          flap_window_start="$now"
          flap_count=0
        fi

        ((flap_count++)) || true
        log "detected missing mic buses (flap_count=$flap_count/60s). re-ensuring..."
        ensure_all

        if (( flap_count >= 12 )); then
          log "FLAP-GUARD: buses are being removed repeatedly. exiting 1 so systemd can back off."
          exit 1
        fi
      else
        # still re-ensure on relevant events (cheap checks + idempotent)
        ensure_all
      fi
    done

    # if subscribe ended, pulse likely restarted
    log "pactl subscribe ended (pulse restart?). waiting + resubscribing..."
    sleep 0.5
    wait_for_pactl || exit 1
    ensure_all
  done
}

main
