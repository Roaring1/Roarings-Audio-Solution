#!/usr/bin/env bash
# roaring_vesktop_stream_watchd.sh  v1.0
# 5/10/2026-1
# Summary: Belt-and-suspenders for Vesktop screen share audio.
#          When venmic creates 'vencord-screen-share' (a null sink), this
#          daemon ensures vm_game.monitor is looped into it.
#          Handles the case where venmic's per-node Flatpak-PID detection
#          fails or "Entire System" mode can't resolve the default-sink
#          monitor from inside the sandbox.
#
# Logic:
#   pactl subscribe watches for sink changes.
#   On vencord-screen-share appearing -> load module-loopback (if not already
#   present from venmic's own "Entire System" handling).
#   On it disappearing -> unload the loopback.
#   Module ID tracked in a state file to survive subshell scope.

LOG="$HOME/.cache/roaring-vesktop-stream-watchd.log"
STATE="$HOME/.cache/roaring-vesktop-stream-watchd.modid"
mkdir -p "$HOME/.cache"
exec >>"$LOG" 2>&1

log() { echo "[vesktop-stream-watch] $(date +%H:%M:%S) $*"; }

wait_for_pactl() {
    local delay=0.5 max=4.0
    until pactl info >/dev/null 2>&1; do
        sleep "$delay"
        delay="$(awk -v d="$delay" -v m="$max" 'BEGIN{x=d*1.5; printf "%.1f",(x>m)?m:x}')"
    done
}

sink_exists() {
    pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "vencord-screen-share"
}

load_loopback() {
    # Bail if we already track a live module
    local tracked_id
    tracked_id="$(cat "$STATE" 2>/dev/null || true)"
    if [[ -n "$tracked_id" ]]; then
        if pactl list short modules 2>/dev/null | awk '{print $1}' | grep -qx "$tracked_id"; then
            log "loopback already active (mod=$tracked_id)"
            return 0
        else
            log "tracked mod=$tracked_id gone, cleaning up"
            rm -f "$STATE"
        fi
    fi

    # Check if venmic's own "Entire System" already created this loopback
    local existing_mod
    existing_mod="$(pactl list short modules 2>/dev/null \
        | grep 'module-loopback' \
        | grep 'vm_game\.monitor' \
        | grep 'vencord-screen-share' \
        | awk '{print $1}' | head -1)"
    if [[ -n "$existing_mod" ]]; then
        log "loopback already exists (venmic Entire System) mod=$existing_mod — tracking"
        echo "$existing_mod" > "$STATE"
        return 0
    fi

    # venmic didn't create it — create belt-and-suspenders loopback
    local new_id
    new_id="$(pactl load-module module-loopback \
        source=vm_game.monitor \
        sink=vencord-screen-share \
        latency_msec=10 \
        rate=48000 \
        channels=2 channel_map=front-left,front-right \
        remix=yes \
        source_dont_move=true sink_dont_move=true 2>/dev/null || true)"
    if [[ -n "$new_id" ]]; then
        echo "$new_id" > "$STATE"
        log "created loopback vm_game.monitor -> vencord-screen-share (mod=$new_id)"
    else
        log "WARN: failed to create loopback (vencord-screen-share may not be ready)"
    fi
}

unload_loopback() {
    local tracked_id
    tracked_id="$(cat "$STATE" 2>/dev/null || true)"
    if [[ -n "$tracked_id" ]]; then
        pactl unload-module "$tracked_id" >/dev/null 2>&1 || true
        rm -f "$STATE"
        log "unloaded loopback mod=$tracked_id"
    fi
}

main() {
    log "starting"
    wait_for_pactl

    # Catch anything already present at startup
    if sink_exists; then
        log "vencord-screen-share already present at startup"
        sleep 0.5
        load_loopback
    fi

    # Event loop
    pactl subscribe 2>/dev/null | while IFS= read -r event; do
        [[ "$event" == *"on sink"* ]] || continue

        if sink_exists; then
            sleep 0.5   # let venmic finish its own linking first
            load_loopback
        else
            unload_loopback
        fi
    done

    log "pactl subscribe exited — restarting in 3s"
    sleep 3
    exec "$0"
}

main
