#!/usr/bin/env bash
set -euo pipefail

# 9/1/2026-6
# Summary: Ensures vm_game/vm_chat/vm_music exist as module-null-sink.
#          Never recreates if already present. Logs only on changes.

LOG="$HOME/.cache/roaring-vm-sinks.log"
mkdir -p "$HOME/.cache"
exec >>"$LOG" 2>&1

log() { echo "[vm_sinks] $(date +%H:%M:%S) $*"; }
wait_for_pactl() { until pactl info >/dev/null 2>&1; do sleep 0.2; done; }

sink_exists() { pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$1"; }

ensure_sink() {
  local name="$1" desc="$2"
  if sink_exists "$name"; then
    return 0
  fi

  pactl load-module module-null-sink \
    sink_name="$name" \
    sink_properties="device.description=$desc" >/dev/null 2>&1 || true

  if sink_exists "$name"; then
    log "created $name ($desc)"
    return 0
  fi

  log "FAILED to create $name"
  return 1
}

main() {
  log "starting"
  while true; do
    wait_for_pactl
    ensure_sink "vm_game"  "VM-GAME"  || true
    ensure_sink "vm_chat"  "VM-CHAT"  || true
    ensure_sink "vm_music" "VM-MUSIC" || true
    sleep 2
  done
}

main
