#!/usr/bin/env bash
set -euo pipefail

# 9/1/2026-1  fix:pactl-storm-1
# Summary: Ensures sm7b_mono/astro_mic_48k sources and B1/B2 loopbacks exist.
#          FIX: ONE sinks + ONE sources + ONE modules list per 3s (was ~15 pactl/s).
# 5/13/2026-2  rm cleanup_mic_monitor_links
# Summary: Removed cleanup_mic_monitor_links() which deleted mic_b?.monitor ->
#          vm_game/vm_chat/vm_music loopbacks every 3s. Those loopbacks are
#          intentionally created by the GUI's loopback toggle (v4.5); the cleanup
#          was fighting the feature. PipeWire does not auto-create these links,
#          so the guard was unnecessary.

CONF="$HOME/.config/roaring_mic_router.conf"
LOG="$HOME/.cache/roaring-mic-routesd.log"
mkdir -p "$HOME/.cache"
exec >>"$LOG" 2>&1

log() { echo "[mic-routesd] $(date +%H:%M:%S) $*"; }
DEDUP_INTERVAL_SEC=30  # was 15 — dedup less often
now_sec() { date +%s; }

wait_for_pactl() {
    local delay=0.5 max=4.0
    until pactl info >/dev/null 2>&1; do
        sleep "$delay"
        delay="$(awk -v d="$delay" -v m="$max" 'BEGIN{x=d*1.5; printf "%.1f", (x>m)?m:x}')"
    done
}

load_conf() {
    B1_ROUTE="astro"
    B2_ROUTE="none"
    LATENCY_MSEC="10"
    RATE="48000"
    # runtime-provided conf path; contents are trusted operator config (SC1090).
    # shellcheck source=/dev/null
    [[ -f "$CONF" ]] && source "$CONF" || true
}

# ── Batched pactl caches ───────────────────────────────────────────────────────
_sinks_cache=""
_sources_cache=""
_modules_cache=""

refresh_all() {
    # THREE pactl calls total per iteration, not 15
    _sinks_cache="$(pactl list short sinks 2>/dev/null)"
    _sources_cache="$(pactl list short sources 2>/dev/null)"
    _modules_cache="$(pactl list short modules 2>/dev/null)"
}

sink_in_cache()   { printf '%s\n' "$_sinks_cache"   | awk '{print $2}' | grep -qx "$1"; }
source_in_cache() { printf '%s\n' "$_sources_cache" | awk '{print $2}' | grep -qx "$1"; }

# Loopback lookup against cached modules — no extra pactl call
loopback_ids_for_pair_cached() {
    local src="$1" sink="$2"
    printf '%s\n' "$_modules_cache" | awk -v s="$src" -v k="$sink" '
        $2=="module-loopback" && $0 ~ ("source=" s) && $0 ~ ("sink=" k) {print $1}
    '
}

loopback_exists_cached() {
    loopback_ids_for_pair_cached "$1" "$2" | grep -q .
}

# ── Module creation helpers (these call pactl when actually needed) ────────────
ensure_sm7b_mono() {
    local master="alsa_input.usb-Focusrite_Scarlett_Solo_USB_Y7XZGYX15C77AB-00.Direct__Direct__source"
    source_in_cache "sm7b_mono" && {
        # Self-healing mute guard: Scarlett input must never be muted.
        # module-device-restore can persist an accidental mute across reboots,
        # silently blocking all mic signal to Carla without any visible error.
        if pactl list sources 2>/dev/null | grep -A3 "$master" | grep -q "Mute: yes"; then
            pactl set-source-mute "$master" 0 >/dev/null 2>&1 || true
            log "auto-unmuted Scarlett source (was muted by device-restore)"
        fi
        return 0
    }
    source_in_cache "$master"   || return 0

    pactl load-module module-remap-source \
        source_name=sm7b_mono \
        master="$master" \
        master_channel_map=front-left \
        channels=1 channel_map=mono remix=no \
        source_properties="device.description=SM7B Mono (L)" >/dev/null 2>&1 || true

    # Targeted re-check, not a full refresh — minimal pactl call
    if pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "sm7b_mono"; then
        log "created source: sm7b_mono"
    else
        log "FAILED to create sm7b_mono"
    fi
}

ensure_astro_mic_48k() {
    local master="alsa_input.usb-Astro_Gaming_Astro_A50-00.mono-chat"
    source_in_cache "astro_mic_48k" && return 0
    source_in_cache "$master"       || return 0

    pactl load-module module-remap-source \
        source_name=astro_mic_48k \
        master="$master" \
        rate="$RATE" \
        channels=1 channel_map=mono remix=no \
        source_properties="device.description=Astro Mic (48k)" >/dev/null 2>&1 || true

    if pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "astro_mic_48k"; then
        log "created source: astro_mic_48k"
    else
        log "FAILED to create astro_mic_48k"
    fi
}

want_contains() { [[ "$1" == "$2" || "$1" == "both" ]]; }

unload_loopbacks_for_pair() {
    local src="$1" sink="$2"
    loopback_ids_for_pair_cached "$src" "$sink" | while read -r id; do
        [[ -n "${id:-}" ]] || continue
        pactl unload-module "$id" >/dev/null 2>&1 || true
    done
}

ensure_loopback() {
    local src="$1" sink="$2" latency="$3" rate="$4"
    loopback_exists_cached "$src" "$sink" && return 0

    pactl load-module module-loopback \
        source="$src" sink="$sink" \
        latency_msec="$latency" rate="$rate" \
        channels=2 channel_map=front-left,front-right remix=yes \
        source_dont_move=true sink_dont_move=true >/dev/null 2>&1 || true

    log "created loopback: $src -> $sink"
}

_last_dedupe_sec=0
dedupe_loopbacks_for_pair() {
    local src="$1" sink="$2"
    local t; t="$(now_sec)"
    (( t - _last_dedupe_sec < DEDUP_INTERVAL_SEC )) && return 0
    _last_dedupe_sec="$t"

    mapfile -t ids < <(loopback_ids_for_pair_cached "$src" "$sink")
    if (( ${#ids[@]} > 1 )); then
        local id
        for id in "${ids[@]:1}"; do
            pactl unload-module "$id" >/dev/null 2>&1 || true
        done
        log "dedupe: kept ${ids[0]} for $src -> $sink (removed $(( ${#ids[@]} - 1 )))"
    fi
}

ensure_routes_exact() {
    load_conf
    local b1_active="${B1_ACTIVE:-true}"
    local b2_active="${B2_ACTIVE:-true}"
    # If active flag is false, force route to "none"
    [[ "$b1_active" != "true" ]] && B1_ROUTE="none"
    [[ "$b2_active" != "true" ]] && B2_ROUTE="none"

    sink_in_cache "mic_b1" || return 0
    sink_in_cache "mic_b2" || return 0

    ensure_sm7b_mono
    ensure_astro_mic_48k

    # Refresh sources after potential creation above
    _sources_cache="$(pactl list short sources 2>/dev/null)"

    local want_sm7b_b1=0 want_astro_b1=0 want_sm7b_b2=0 want_astro_b2=0
    want_contains "$B1_ROUTE" "sm7b"  && want_sm7b_b1=1
    want_contains "$B1_ROUTE" "astro" && want_astro_b1=1
    want_contains "$B2_ROUTE" "sm7b"  && want_sm7b_b2=1
    want_contains "$B2_ROUTE" "astro" && want_astro_b2=1

    local changed=0

    if (( want_sm7b_b1 )); then
        ensure_loopback sm7b_mono mic_b1 "$LATENCY_MSEC" "$RATE" && changed=1
        dedupe_loopbacks_for_pair sm7b_mono mic_b1
    else
        unload_loopbacks_for_pair sm7b_mono mic_b1 && changed=1
    fi

    if (( want_astro_b1 )); then
        ensure_loopback astro_mic_48k mic_b1 "$LATENCY_MSEC" "$RATE" && changed=1
        dedupe_loopbacks_for_pair astro_mic_48k mic_b1
    else
        unload_loopbacks_for_pair astro_mic_48k mic_b1 && changed=1
    fi

    if (( want_sm7b_b2 )); then
        ensure_loopback sm7b_mono mic_b2 "$LATENCY_MSEC" "$RATE" && changed=1
        dedupe_loopbacks_for_pair sm7b_mono mic_b2
    else
        unload_loopbacks_for_pair sm7b_mono mic_b2 && changed=1
    fi

    if (( want_astro_b2 )); then
        ensure_loopback astro_mic_48k mic_b2 "$LATENCY_MSEC" "$RATE" && changed=1
        dedupe_loopbacks_for_pair astro_mic_48k mic_b2
    else
        unload_loopbacks_for_pair astro_mic_48k mic_b2 && changed=1
    fi

    # Only refresh module cache if something changed
    (( changed )) && _modules_cache="$(pactl list short modules 2>/dev/null)" || true
}

main() {
    log "starting (pactl-storm fix: 3 lists/3s)"
    while true; do
        wait_for_pactl
        refresh_all         # 3 pactl calls total — sinks, sources, modules
        ensure_routes_exact || true
        sleep 3             # was 1 — reduced from ~15 pactl/s to ~1/s
    done
}

main
