#!/usr/bin/env bash
set -euo pipefail

# 10/1/2026-2  fix:pactl-storm-1
# Summary: Keeps VM audio routed to Astro target via module-loopback.
#          FIX: ONE sinks + ONE modules list per 5s iteration (was ~4 pactl/s).
# 5/13/2026-3  restore_mic_listen guardian
# Summary: After each iteration, check ~/.cache/roaring_mic_listen/{b1,b2}.ids.
#          If the state file says ON but the loopback is gone (reboot/PW restart),
#          auto-restore it to the current Astro target.

LOG="$HOME/.cache/roaring-audio-routesd.log"
mkdir -p "$HOME/.cache"
exec >>"$LOG" 2>&1

CONF="$HOME/.config/roaring_mixer.conf"
STATE_FILE="$HOME/.cache/roaring-audio-routesd.target"

ENV_LATENCY_MSEC="${LATENCY_MSEC:-40}"
ENV_ASTRO_TARGET="${ASTRO_TARGET:-}"
ENV_ASTRO_MATCH_RE="${ASTRO_MATCH_RE:-Astro}"
DEDUP_INTERVAL_SEC=30  # was 15

log() { echo "[audio-routesd] $(date +%H:%M:%S) $*"; }
now_sec() { date +%s; }

load_conf() {
    LATENCY_MSEC="$ENV_LATENCY_MSEC"
    ASTRO_TARGET="$ENV_ASTRO_TARGET"
    ASTRO_MATCH_RE="$ENV_ASTRO_MATCH_RE"
    # runtime-provided conf path; contents are trusted operator config (SC1090).
    # shellcheck source=/dev/null
    [[ -f "$CONF" ]] && source "$CONF" || true
}

wait_for_pactl() {
    local delay=0.5 max=4.0
    until pactl info >/dev/null 2>&1; do
        sleep "$delay"
        delay="$(awk -v d="$delay" -v m="$max" 'BEGIN{x=d*1.5; printf "%.1f", (x>m)?m:x}')"
    done
}

# ── Batched pactl caches ───────────────────────────────────────────────────────
_sinks_cache=""
_modules_cache=""

refresh_sinks()   { _sinks_cache="$(pactl list short sinks 2>/dev/null)"; }
refresh_modules() { _modules_cache="$(pactl list short modules 2>/dev/null)"; }
refresh_all()     { refresh_sinks; refresh_modules; }

sink_in_cache() { printf '%s\n' "$_sinks_cache" | awk '{print $2}' | grep -qx "$1"; }

# ── Astro target detection against cached sink list ────────────────────────────
find_astro_target() {
    # If user pinned ASTRO_TARGET and it exists in our cache, use it directly
    if [[ -n "$ASTRO_TARGET" ]] && sink_in_cache "$ASTRO_TARGET"; then
        echo "$ASTRO_TARGET"
        return 0
    fi

    # Fallback: match by sink name from cached list
    local by_name=""
    by_name="$(printf '%s\n' "$_sinks_cache" | awk '{print $2}' | grep -Ei "$ASTRO_MATCH_RE" | head -n 1 || true)"
    if [[ -n "$by_name" ]]; then
        echo "$by_name"
        return 0
    fi

    # Last resort: full sink listing — only runs when name-match fails (rare)
    local by_desc=""
    by_desc="$(
        pactl list sinks 2>/dev/null \
            | awk '
                BEGIN{RS="Sink #"; FS="\n"}
                NR>1{
                    name=""; desc=""
                    for(i=1;i<=NF;i++){
                        if($i ~ /^[[:space:]]*Name:/){sub(/^[[:space:]]*Name:[[:space:]]*/,"",$i); name=$i}
                        if($i ~ /device\.description/){sub(/.*= "/,"",$i); sub(/".*$/,"",$i); desc=$i}
                    }
                    if(name!="" && desc!=""){print name "\t" desc}
                }' \
            | grep -Ei "$ASTRO_MATCH_RE" \
            | head -n 1 \
            | awk '{print $1}' \
            || true
    )"
    echo "$by_desc"
}

# ── Loopback helpers against cached module list ────────────────────────────────
_loopback_ids_for_pair() {
    local src="$1" sink="$2"
    printf '%s\n' "$_modules_cache" | awk -v s="$src" -v k="$sink" '
        $2=="module-loopback" && $0 ~ ("source=" s) && $0 ~ ("sink=" k) {print $1}
    '
}

loopback_exists_cached() {
    _loopback_ids_for_pair "$1" "$2" | grep -q .
}

unload_vm_loopbacks_to_sink() {
    local sink="$1"
    printf '%s\n' "$_modules_cache" | awk -v k="$sink" '
        $2=="module-loopback" &&
        ($0 ~ /source=vm_game\.monitor/ || $0 ~ /source=vm_chat\.monitor/ || $0 ~ /source=vm_music\.monitor/) &&
        $0 ~ ("sink=" k) {print $1}
    ' | while read -r id; do
        [[ -n "${id:-}" ]] || continue
        pactl unload-module "$id" >/dev/null 2>&1 || true
    done
}

ensure_loopback() {
    local src="$1" sink="$2"
    loopback_exists_cached "$src" "$sink" && return 0

    pactl load-module module-loopback \
        source="$src" sink="$sink" latency_msec="$LATENCY_MSEC" >/dev/null 2>&1 || true

    # Targeted re-check for this specific loopback
    local new_mod
    new_mod="$(pactl list short modules 2>/dev/null | awk -v s="$src" -v k="$sink" '
        $2=="module-loopback" && $0 ~ ("source=" s) && $0 ~ ("sink=" k) {print $1; exit}
    ')"
    if [[ -n "$new_mod" ]]; then
        log "created loopback: source=$src -> sink=$sink (latency=${LATENCY_MSEC}ms)"
        refresh_modules  # keep cache current
    else
        log "FAILED create loopback: source=$src -> sink=$sink"
    fi
}

# ── Mic listen (sidetone) guardian ────────────────────────────────────────────
# toggle_mic_listen.sh stores module IDs in ~/.cache/roaring_mic_listen/{b1,b2}.ids.
# After a PipeWire restart the modules are gone but the state files remain, so
# the sidetone silently disappears until the user manually re-toggles.
# This function runs each iteration and re-creates any loopback whose state file
# says ON but whose modules are no longer present.
MIC_LISTEN_STATE_DIR="$HOME/.cache/roaring_mic_listen"
restore_mic_listen() {
    local target="$1"
    local bus src state id mods
    mods="$_modules_cache"
    for bus in b1 b2; do
        state="$MIC_LISTEN_STATE_DIR/${bus}.ids"
        [[ -f "$state" ]] || continue
        src="mic_${bus}.monitor"
        # Check if any stored ID is still a live loopback for this source
        local live=0
        while read -r id; do
            [[ -n "${id:-}" ]] || continue
            if printf '%s\n' "$mods" | awk -v i="$id" -v s="$src" \
                'BEGIN{f=0} $1==i && $2=="module-loopback" && $0~("source="s){f=1} END{exit !f}'; then
                live=1; break
            fi
        done < "$state"
        if (( live == 0 )); then
            # Stale — re-create loopback and update state file
            id="$(pactl load-module module-loopback \
                source="$src" sink="$target" latency_msec=18 rate=48000 \
                channels=2 remix=yes \
                source_dont_move=true sink_dont_move=true 2>/dev/null || true)"
            if [[ -n "${id:-}" ]]; then
                printf '%s\n' "$id" > "$state"
                log "restored mic listen $bus: $src -> $target (id=$id)"
                refresh_modules
            else
                rm -f "$state"
                log "FAILED restore mic listen $bus: $src -> $target"
            fi
        fi
    done
}

_last_dedupe_sec=0
dedupe_loopbacks_for_target() {
    local target="$1"
    local t; t="$(now_sec)"
    (( t - _last_dedupe_sec < DEDUP_INTERVAL_SEC )) && return 0
    _last_dedupe_sec="$t"

    local src changed=0
    for src in vm_game.monitor vm_chat.monitor vm_music.monitor; do
        mapfile -t ids < <(_loopback_ids_for_pair "$src" "$target")
        if (( ${#ids[@]} > 1 )); then
            local id
            for id in "${ids[@]:1}"; do
                pactl unload-module "$id" >/dev/null 2>&1 || true
            done
            log "dedupe: kept ${ids[0]} for $src -> $target (removed $(( ${#ids[@]} - 1 )))"
            changed=1
        fi
    done
    (( changed )) && refresh_modules || true
}

main() {
    load_conf
    log "starting (pactl-storm fix: 2 lists/5s, LATENCY=${LATENCY_MSEC}ms)"
    while true; do
        wait_for_pactl
        load_conf

        # Two pactl calls per 5s iteration (sinks + modules)
        refresh_all

        local target=""
        target="$(find_astro_target)"

        if [[ -z "$target" ]]; then
            log "no Astro target detected yet; sleeping..."
            sleep 2
            continue
        fi

        local last=""
        last="$(cat "$STATE_FILE" 2>/dev/null || true)"
        if [[ -n "$last" && "$last" != "$target" ]]; then
            log "target changed: $last -> $target; removing old loopbacks"
            unload_vm_loopbacks_to_sink "$last"
            refresh_modules
        fi
        [[ "$last" != "$target" ]] && printf '%s\n' "$target" > "$STATE_FILE"

        ensure_loopback "vm_game.monitor"  "$target"
        ensure_loopback "vm_chat.monitor"  "$target"
        ensure_loopback "vm_music.monitor" "$target"
        dedupe_loopbacks_for_target "$target"
        restore_mic_listen "$target"

        sleep 5    # was 2 — reduced from ~4 pactl/s to ~0.4/s
    done
}

main
