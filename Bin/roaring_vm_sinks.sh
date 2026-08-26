#!/usr/bin/env bash
set -euo pipefail

# 9/1/2026-6  fix:pactl-storm-1
# Summary: Ensures vm_game/vm_chat/vm_music exist as module-null-sink.
#          FIX: ONE pactl call per 5s iteration (was 4 pactl/s). No redundant polls.

LOG="$HOME/.cache/roaring-vm-sinks.log"
mkdir -p "$HOME/.cache"
exec >>"$LOG" 2>&1

log() { echo "[vm_sinks] $(date +%H:%M:%S) $*"; }

# Exponential backoff — avoids hammering PipeWire when it's overloaded
wait_for_pactl() {
    local delay=0.5 max=4.0
    until pactl info >/dev/null 2>&1; do
        sleep "$delay"
        delay="$(awk -v d="$delay" -v m="$max" 'BEGIN{x=d*1.5; printf "%.1f", (x>m)?m:x}')"
    done
}

# ── Batched sink cache — ONE pactl list call per iteration ────────────────────
_sinks_cache=""

refresh_sinks() {
    _sinks_cache="$(pactl list short sinks 2>/dev/null)"
}

sink_in_cache() {
    printf '%s\n' "$_sinks_cache" | awk '{print $2}' | grep -qx "$1"
}

ensure_sink() {
    local name="$1" desc="$2"
    sink_in_cache "$name" && return 0

    pactl load-module module-null-sink \
        sink_name="$name" \
        object.linger=1 \
        sink_properties="device.description=$desc" >/dev/null 2>&1 || true

    # Minimal targeted re-check — only runs on first creation
    if pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$name"; then
        log "created $name ($desc)"
        refresh_sinks  # keep cache current after a change
    else
        log "FAILED to create $name"
    fi
}

# ── Default sink guardian ─────────────────────────────────────────────────────
# vm_game must be the system default sink at all times.
# Browsers, PulseAudio device-restore, and any newly-connected device can
# silently steal the default, routing new app audio to hardware instead of
# the VM pipeline.  Log every external change and immediately restore.
ensure_default_sink() {
    local want="$1"
    sink_in_cache "$want" || return 0
    local cur
    cur="$(pactl get-default-sink 2>/dev/null || true)"
    [[ "$cur" == "$want" ]] && return 0
    pactl set-default-sink "$want" >/dev/null 2>&1 || true
    log "HEAL default-sink: '$cur' → '$want' (external change detected)"
}

main() {
    log "starting (pactl-storm fix: 1 list/5s)"
    while true; do
        wait_for_pactl
        refresh_sinks              # single pactl list short sinks for all three checks
        ensure_sink "vm_game"  "VM-GAME"
        ensure_sink "vm_chat"  "VM-CHAT"
        ensure_sink "vm_music" "VM-MUSIC"
        ensure_default_sink "vm_game"
        sleep 5                    # was 2 — reduced from ~2 pactl/s to ~0.2/s
    done
}

main
