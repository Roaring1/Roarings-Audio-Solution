#!/usr/bin/env bash
set -euo pipefail

# 4/12/2026-1
# Summary: Streams mic source → Windows host over UDP for Moonlight mic passthrough.
#          Source, IP, and port are injected via systemd Environment= vars.
#          Follows roaring daemon pattern: wait → stream → retry on failure.

LOG="$HOME/.cache/roaring-moonlight-micd.log"
mkdir -p "$HOME/.cache"
exec >>"$LOG" 2>&1

WINDOWS_IP="${MOONLIGHT_HOST_IP:-}"
MIC_SOURCE="${MIC_SOURCE:-b2_mic}"
MIC_PORT="${MIC_PORT:-46001}"
RATE=48000
CHANNELS=1
RETRY_SEC=3

log() { echo "[moonlight-micd] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# ── Guard ──────────────────────────────────────────────────────────────────────
if [[ -z "$WINDOWS_IP" ]]; then
  log "FATAL: MOONLIGHT_HOST_IP not set — edit $HOME/.config/systemd/user/roaring-moonlight-mic.service"
  exit 1
fi

# ── Helpers ────────────────────────────────────────────────────────────────────
wait_for_pactl() {
  local delay=0.5 max=4.0
  until pactl info >/dev/null 2>&1; do
    sleep "$delay"
    delay="$(awk -v d="$delay" -v m="$max" 'BEGIN{x=d*1.5; printf "%.1f", (x>m)?m:x}')"
  done
}

wait_for_source() {
  local delay=0.5 max=4.0
  until pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "$MIC_SOURCE"; do
    wait_for_pactl
    sleep "$delay"
    delay="$(awk -v d="$delay" -v m="$max" 'BEGIN{x=d*1.5; printf "%.1f", (x>m)?m:x}')"
  done
  log "source ready: $MIC_SOURCE"
}

stream_mic() {
  # Capture from PipeWire/PulseAudio source and stream raw PCM over UDP.
  # Windows side decodes with ffmpeg → VB-Audio Cable Input (see receive_mic.bat).
  # NOTE: -use_wallclock_as_timestamps was removed — it substitutes jittery wall-clock
  # times for PulseAudio timestamps, causing non-monotonic DTS spam that corrupts
  # the UDP stream on the receiver side.  aresample=async=1 handles clock drift.
  ffmpeg \
    -f pulse \
    -i "$MIC_SOURCE" \
    -af aresample=async=1:min_hard_comp=0.1 \
    -ar "$RATE" \
    -ac "$CHANNELS" \
    -f s16le \
    -fflags +nobuffer \
    "udp://${WINDOWS_IP}:${MIC_PORT}?pkt_size=1316" \
    -loglevel error \
    2>&1 | while IFS= read -r line; do log "ffmpeg: $line"; done
  return "${PIPESTATUS[0]}"
}

# ── Main loop ──────────────────────────────────────────────────────────────────
log "starting — source=${MIC_SOURCE} → udp://${WINDOWS_IP}:${MIC_PORT} (${RATE}Hz mono)"

while true; do
  wait_for_pactl
  wait_for_source
  stream_mic || true
  log "stream ended — retrying in ${RETRY_SEC}s..."
  sleep "$RETRY_SEC"
done
