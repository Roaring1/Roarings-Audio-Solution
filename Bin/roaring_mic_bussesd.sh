#!/usr/bin/env bash
set -euo pipefail

# 9/1/2026-1
# Summary:
# - Ensures mic_b1 + mic_b2 virtual sinks exist (each sink creates a *.monitor source).
# - Creates remapped sources b1_mic and b2_mic so apps see them as normal microphones.
# - Sets default source to b2_mic (your "games/default" bus).

LOG="$HOME/.cache/roaring-mic-bussesd.log"
mkdir -p "$HOME/.cache"
exec >>"$LOG" 2>&1

log() { echo "[mic-bus] $(date +%H:%M:%S) $*"; }
wait_for_pactl() { until pactl info >/dev/null 2>&1; do sleep 0.2; done; }

sink_exists()   { pactl list short sinks   2>/dev/null | awk '{print $2}' | grep -qx "$1"; }
source_exists() { pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "$1"; }

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

set_default_source_if_present() {
  local src="$1"
  source_exists "$src" || return 0
  pactl set-default-source "$src" >/dev/null 2>&1 || true
}

main() {
  log "starting"
  while true; do
    wait_for_pactl

    ensure_null_sink "mic_b1" "B1"
    ensure_null_sink "mic_b2" "B2"

    # Each sink creates a monitor source; remap those monitors into normal mic sources.
    ensure_remap_source "b1_mic" "B1 Mic" "mic_b1.monitor"
    ensure_remap_source "b2_mic" "B2 Mic" "mic_b2.monitor"

    # Your default input bus = B2
    set_default_source_if_present "b2_mic"

    sleep 1
  done
}

main
