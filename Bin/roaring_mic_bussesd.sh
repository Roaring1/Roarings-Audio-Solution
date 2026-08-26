#!/usr/bin/env bash
set -euo pipefail

# 9/1/2026-1  fix:pactl-storm-1
# Summary: Ensures mic_b1+mic_b2 virtual sinks + remapped sources exist.
#          FIX: ONE pactl list sinks + ONE list sources per 5s (was ~8 pactl/s).
# 5/10/2026-2  discord_stream
# Summary: Added discord_stream remap-source (vm_game.monitor) — stable named
#          capture point for Vesktop screen-share "Entire System" mode.
# 5/11/2026-3  vencord-screen-share-vol + rm discord_stream
# Summary: Removed discord_stream (dead code — portal does its own linking;
#          Vesktop never captured from it). Added ensure_source_volume_100 guard
#          for vencord-screen-share: stream-restore was restoring it to 27%
#          (-33.69 dB) on every screenshare start; now healed to 100% within 5s.

LOG="$HOME/.cache/roaring-mic-bussesd.log"
mkdir -p "$HOME/.cache"
exec >>"$LOG" 2>&1

# Gap #1 fix: which source apps auto-pick when they don't hardcode a target.
# The audit's intent is b1_mic (the Carla-processed mic), NOT b2_mic (raw).
# This guardian heals by NAME via pactl, so it is immune to the node-ID churn
# that broke the audit's proposed by-ID `wpctl set-default` oneshot, and it
# re-asserts within one loop if anything (or WirePlumber state) flips it back.
# Override in ~/.config/roaring_mixer.conf with e.g. DEFAULT_SOURCE="b2_mic".
DEFAULT_SOURCE="${DEFAULT_SOURCE:-b1_mic}"

log() { echo "[mic-bus] $(date +%H:%M:%S) $*"; }

wait_for_pactl() {
    local delay=0.5 max=4.0
    until pactl info >/dev/null 2>&1; do
        sleep "$delay"
        delay="$(awk -v d="$delay" -v m="$max" 'BEGIN{x=d*1.5; printf "%.1f", (x>m)?m:x}')"
    done
}

# ── Batched pactl caches ───────────────────────────────────────────────────────
_sinks_cache=""
_sources_cache=""

refresh_sinks()   { _sinks_cache="$(pactl list short sinks 2>/dev/null)"; }
refresh_sources() { _sources_cache="$(pactl list short sources 2>/dev/null)"; }

sink_in_cache()   { printf '%s\n' "$_sinks_cache"   | awk '{print $2}' | grep -qx "$1"; }
source_in_cache() { printf '%s\n' "$_sources_cache" | awk '{print $2}' | grep -qx "$1"; }

ensure_null_sink() {
    local name="$1" desc="$2"
    sink_in_cache "$name" && return 0

    pactl load-module module-null-sink \
        sink_name="$name" \
        object.linger=1 \
        rate=48000 channels=2 channel_map=front-left,front-right \
        sink_properties="device.description=$desc" >/dev/null 2>&1 || true

    if pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$name"; then
        log "created sink: $name ($desc)"
        refresh_sinks
    else
        log "FAILED to create sink: $name"
    fi
}

ensure_remap_source() {
    local src_name="$1" desc="$2" master="$3"
    source_in_cache "$src_name" && return 0
    source_in_cache "$master"   || return 0  # master not ready yet

    pactl load-module module-remap-source \
        source_name="$src_name" \
        master="$master" \
        remix=yes rate=48000 channels=2 channel_map=front-left,front-right \
        source_properties="device.description=$desc" >/dev/null 2>&1 || true

    if pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "$src_name"; then
        log "created source: $src_name ($desc) -> master=$master"
        refresh_sources
    else
        log "FAILED to create source: $src_name"
    fi
}

# ── Self-healing guardians for pipeline-internal sinks/sources ────────────────
# mic_b1, mic_b2 are null sinks used purely as internal pipeline nodes.
# No user control (fader, LPD8 pad, RAC button) operates on their volume or
# mute state — they must stay at unity gain and unmuted.  Any external
# change (pavucontrol scroll, app auto-routing) is a fault; log + restore.

ensure_sink_volume_100() {
    local name="$1"
    sink_in_cache "$name" || return 0
    local raw pct
    raw="$(pactl get-sink-volume "$name" 2>/dev/null || true)"
    pct="$(echo "$raw" | grep -oP '\d+(?=%)' | head -1 || true)"
    [[ "${pct:-100}" == "100" ]] && return 0
    pactl set-sink-volume "$name" 100% >/dev/null 2>&1 || true
    log "HEAL volume $name: ${pct}% → 100% (pipeline node must be unity gain)"
}

ensure_sink_not_muted() {
    local name="$1"
    sink_in_cache "$name" || return 0
    local muted
    muted="$(pactl get-sink-mute "$name" 2>/dev/null | awk '{print $2}' || true)"
    [[ "$muted" == "yes" ]] || return 0
    pactl set-sink-mute "$name" 0 >/dev/null 2>&1 || true
    log "HEAL mute $name: muted → unmuted (pipeline node must not be muted)"
}

ensure_source_volume_100() {
    local name="$1"
    source_in_cache "$name" || return 0
    local raw pct
    raw="$(pactl get-source-volume "$name" 2>/dev/null || true)"
    pct="$(echo "$raw" | grep -oP '\d+(?=%)' | head -1 || true)"
    [[ "${pct:-100}" == "100" ]] && return 0
    pactl set-source-volume "$name" 100% >/dev/null 2>&1 || true
    log "HEAL volume $name: ${pct}% → 100% (remap source must be unity gain)"
}

# ── Default source guardian ───────────────────────────────────────────────
# $DEFAULT_SOURCE must be the system default source (Discord, browser, apps
# auto-pick it). Log + restore on every external change.
ensure_default_source() {
    local want="$1"
    source_in_cache "$want" || return 0
    local cur
    cur="$(pactl get-default-source 2>/dev/null || true)"
    [[ "$cur" == "$want" ]] && return 0
    pactl set-default-source "$want" >/dev/null 2>&1 || true
    log "HEAL default-source: '$cur' → '$want' (external change detected)"
}

main() {
    log "starting (pactl-storm fix: 2 lists/5s)"
    while true; do
        wait_for_pactl

        # Two pactl calls per 5s iteration (sinks + sources), not 8
        refresh_sinks
        refresh_sources

        ensure_null_sink "mic_b1" "B1"
        ensure_null_sink "mic_b2" "B2"

        ensure_remap_source "b1_mic" "B1 Mic" "mic_b1.monitor"
        ensure_remap_source "b2_mic" "B2 Mic" "mic_b2.monitor"

        # Pipeline-internal guardians (all cheap: pactl get-* is one call each)
        ensure_sink_volume_100  "mic_b1"
        ensure_sink_volume_100  "mic_b2"
        ensure_sink_not_muted   "mic_b1"
        ensure_sink_not_muted   "mic_b2"
        ensure_source_volume_100 "b1_mic"
        ensure_source_volume_100 "b2_mic"
        ensure_default_source    "$DEFAULT_SOURCE"

        # vencord-screen-share: ephemeral PW virtual source created by Vencord's
        # screenshare plugin. stream-restore restores it to a stale 27% every
        # session. Heal to 100% whenever it exists; no-op when absent.
        ensure_source_volume_100 "vencord-screen-share"

        sleep 5    # was 1 — reduced from ~8 pactl/s to ~0.4/s
    done
}

# Only auto-run when executed directly; allows sourcing functions in tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
