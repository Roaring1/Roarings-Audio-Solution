#!/usr/bin/env bash
set -euo pipefail

# 4/17/2026-1
# Summary: Streams laptop_audio.monitor → Windows host over UDP (stereo s16le).
#          Mirrors roaring_moonlight_micd.sh pattern exactly.

LOG="$HOME/.cache/roaring-laptop-audiod.log"
mkdir -p "$HOME/.cache"
exec >>"$LOG" 2>&1

WINDOWS_IP="${LAPTOP_HOST_IP:-}"
AUDIO_SOURCE="${AUDIO_SOURCE:-laptop_audio.monitor}"
AUDIO_PORT="${AUDIO_PORT:-46000}"
RATE=48000
CHANNELS=2
RETRY_SEC=3

log() { echo "[laptop-audiod] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

if [[ -z "$WINDOWS_IP" ]]; then
    log "FATAL: LAPTOP_HOST_IP not set in service Environment="
    exit 1
fi

wait_for_pactl() {
    local delay=0.5 max=4.0
    until pactl info >/dev/null 2>&1; do
        sleep "$delay"
        delay="$(awk -v d="$delay" -v m="$max" 'BEGIN{x=d*1.5; printf "%.1f", (x>m)?m:x}')"
    done
}

wait_for_source() {
    local delay=0.5 max=4.0
    until pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "$AUDIO_SOURCE"; do
        wait_for_pactl
        sleep "$delay"
        delay="$(awk -v d="$delay" -v m="$max" 'BEGIN{x=d*1.5; printf "%.1f", (x>m)?m:x}')"
    done
    log "source ready: $AUDIO_SOURCE"
}

stream_audio() {
    # NOTE: -use_wallclock_as_timestamps was removed (same bug as moonlight).
    # It substitutes jittery wall-clock for PulseAudio timestamps, causing
    # non-monotonic DTS spam that balloons the log file (was 8MB+).
    # aresample=async=1 handles real clock drift cleanly.
    ffmpeg \
        -f pulse \
        -i "$AUDIO_SOURCE" \
        -af aresample=async=1:min_hard_comp=0.1 \
        -ar "$RATE" \
        -ac "$CHANNELS" \
        -f s16le \
        -fflags +nobuffer \
        "udp://${WINDOWS_IP}:${AUDIO_PORT}?pkt_size=1316" \
        -loglevel error \
        2>&1 | while IFS= read -r line; do log "ffmpeg: $line"; done
    return "${PIPESTATUS[0]}"
}

log "starting — source=${AUDIO_SOURCE} → udp://${WINDOWS_IP}:${AUDIO_PORT} (${RATE}Hz stereo)"
while true; do
    wait_for_pactl
    wait_for_source
    stream_audio || true
    log "stream ended — retrying in ${RETRY_SEC}s..."
    sleep "$RETRY_SEC"
done
