#!/usr/bin/env bash
set -euo pipefail

# 9/20/2026-1  peer presence gating
# Summary: the stream now starts only when the laptop answers a ping and stops
#          within ~2s of it going away, instead of sending mic audio at an
#          address that is not there. Coming back is not treated as a failure,
#          so it does not inherit the exponential backoff.
# 4/12/2026-1
# Summary: Streams mic source → Windows host over UDP for Moonlight mic passthrough.
#          Source, IP, and port are injected via systemd Environment= vars.
#          Follows roaring daemon pattern: wait → stream → retry on failure.

LOG="$HOME/.cache/roaring-moonlight-micd.log"
mkdir -p "$HOME/.cache"
exec >>"$LOG" 2>&1

WINDOWS_IP="${MOONLIGHT_HOST_IP:-}"
MIC_SOURCE="${MIC_SOURCE:-b1_mic}"
MIC_PORT="${MIC_PORT:-46001}"
RATE=48000
CHANNELS=1
RETRY_SEC=3
# Recycle ffmpeg after this many resampler glitches (see MEMORY note below).
GLITCH_LIMIT="${GLITCH_LIMIT:-3}"
MAX_BACKOFF_SEC=60
# How often to check that the laptop is still there, and how many misses end
# the stream. Two seconds of silence from a machine on the same wired LAN is
# already conclusive.
PEER_POLL_SEC="${PEER_POLL_SEC:-2}"
PEER_MISS_LIMIT="${PEER_MISS_LIMIT:-2}"

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

peer_up() {
  ping -c1 -W1 "$WINDOWS_IP" >/dev/null 2>&1
}

wait_for_peer() {
  local announced=0
  until peer_up; do
    if (( announced == 0 )); then
      log "laptop ${WINDOWS_IP} not reachable - holding the mic stream"
      announced=1
    fi
    sleep "$PEER_POLL_SEC"
  done
  if (( announced )); then
    log "laptop ${WINDOWS_IP} is back - resuming"
  fi
}

# Kills the given ffmpeg as soon as the laptop stops answering. Runs beside the
# stream and exits with it, so the main loop's backoff logic is untouched.
watch_peer() {
  local ff="$1" misses=0
  while kill -0 "$ff" 2>/dev/null; do
    sleep "$PEER_POLL_SEC"
    if peer_up; then
      misses=0
    else
      misses=$((misses + 1))
      if (( misses >= PEER_MISS_LIMIT )); then
        log "laptop ${WINDOWS_IP} went away - stopping the stream"
        kill "$ff" 2>/dev/null || true
        return 0
      fi
    fi
  done
}

stream_mic() {
  # Capture from PipeWire/PulseAudio source and stream raw PCM over UDP.
  # Windows side decodes with ffmpeg → VB-Audio Cable Input (see receive_mic.bat).
  # NOTE: -use_wallclock_as_timestamps was removed — it substitutes jittery wall-clock
  # times for PulseAudio timestamps, causing non-monotonic DTS spam that corrupts
  # the UDP stream on the receiver side.  aresample=async=1 handles clock drift.
  #
  # MEMORY: when the source suspends/resumes, PulseAudio's PTS jumps by the
  # whole idle gap and libswresample tries to bridge it with silence. It logs
  # "Failed to compensate for timestamp delta" and grows an internal buffer it
  # never releases for the life of the process. Measured on this rig: a healthy
  # sender is a flat 74.7MB, but one 9-error burst added 124MB and 4.5 days of
  # them reached 1.8GB resident+swap -- per stream. So we watch stderr and
  # recycle ffmpeg once a burst starts; the outer loop restarts it.
  local fifo_dir fifo
  fifo_dir="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/moonlight-micd.XXXXXX")" || return 1
  fifo="$fifo_dir/stderr.fifo"
  if ! mkfifo -m 600 "$fifo"; then
    rmdir "$fifo_dir" 2>/dev/null || true
    return 1
  fi

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
    2>"$fifo" &
  local ff=$!

  watch_peer "$ff" &
  local watcher=$!

  local glitches=0
  while IFS= read -r line; do
    log "ffmpeg: $line"
    case "$line" in
      *"Failed to compensate for timestamp delta"*)
        glitches=$((glitches + 1))
        if [[ $glitches -ge $GLITCH_LIMIT ]]; then
          log "resampler glitch x${glitches} - recycling ffmpeg to release its buffers"
          kill "$ff" 2>/dev/null || true
          break
        fi
        ;;
    esac
  done <"$fifo"

  local rc=0
  wait "$ff" || rc=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  rm -f "$fifo"
  rmdir "$fifo_dir" 2>/dev/null || true
  return "$rc"
}

# ── Main loop ──────────────────────────────────────────────────────────────────
# Each stream_mic() run makes a private stderr FIFO and deletes it on the way
# out, but a SIGKILL (or a cgroup OOM kill) skips that cleanup and leaves the
# node behind in XDG_RUNTIME_DIR. Only one instance of this daemon ever runs,
# so anything matching the pattern at startup is stale by definition.
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
# A private directory avoids the mktemp -u name race. Remove only stale
# directories owned by this user and matching this daemon's namespace.
find "$RUNTIME_DIR" -mindepth 1 -maxdepth 1 -type d -uid "$(id -u)" \
  -name 'moonlight-micd.*' -exec rm -rf -- {} + 2>/dev/null || true
# Clean legacy FIFO names left by versions that used mktemp -u.
rm -f "$RUNTIME_DIR"/moonlight-micd.?????? 2>/dev/null || true

log "starting — source=${MIC_SOURCE} → udp://${WINDOWS_IP}:${MIC_PORT} (${RATE}Hz mono)"

backoff="$RETRY_SEC"
while true; do
  wait_for_pactl
  wait_for_source
  wait_for_peer
  started=$SECONDS
  stream_mic || true
  ran=$((SECONDS - started))
  # A healthy stream runs for hours. If it keeps dying immediately the fault
  # is persistent, so back off instead of spinning on it.
  if ! peer_up; then
    # The laptop leaving is not a fault. Reset the backoff so the stream is
    # running again within a poll of it coming back.
    backoff="$RETRY_SEC"
  elif [[ $ran -lt 30 ]]; then
    backoff=$((backoff * 2))
    [[ $backoff -gt $MAX_BACKOFF_SEC ]] && backoff="$MAX_BACKOFF_SEC"
  else
    backoff="$RETRY_SEC"
  fi
  log "stream ended after ${ran}s — retrying in ${backoff}s..."
  sleep "$backoff"
done
