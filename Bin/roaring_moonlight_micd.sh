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
# Pulse capture fragments are mono s16le bytes and may span one 1024-frame
# graph cycle (2048 bytes). The filter chain below splits them into 512-sample
# frames and paces by PTS. Each resulting UDP datagram is always 1024 bytes;
# do not confuse the larger Pulse capture fragment with the network packet size.
PULSE_FRAGMENT_OVERRIDE="${PULSE_FRAGMENT_BYTES:-}"
PULSE_FRAGMENT_BYTES=960
PULSE_FRAGMENT_FALLBACK=0
PULSE_FRAGMENT_MAX=2048
# Learned minimum stable graph period for this machine. Set
# ROARING_MIC_MIN_QUANTUM=256 only to opt into further 5.33 ms trials.
MIN_SAFE_QUANTUM="$(printenv ROARING_MIC_MIN_QUANTUM 2>/dev/null || echo 512)"
case "$MIN_SAFE_QUANTUM" in 256|512|1024) ;; *) MIN_SAFE_QUANTUM=512 ;; esac
SAFE_QUANTUM_FILE="$HOME/.config/roaring/mic-safe-quantum"
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
pipewire_quantum() {
  local settings forced quantum
  settings="$(pw-metadata -n settings 2>/dev/null || true)"
  forced="$(printf '%s\n' "$settings" |
    sed -n "s/.*key:'clock.force-quantum' value:'\([0-9][0-9]*\)'.*/\1/p" | tail -n1)"
  if [[ "$forced" =~ ^[0-9]+$ ]] && (( forced > 0 )); then
    printf '%s\n' "$forced"
    return 0
  fi
  quantum="$(printf '%s\n' "$settings" |
    sed -n "s/.*key:'clock.quantum' value:'\([0-9][0-9]*\)'.*/\1/p" | tail -n1)"
  [[ "$quantum" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$quantum"
}

parse_scarlett_xrun_count() {
  awk '
    $1 == "R" &&
    $0 ~ /alsa_input\.usb-Focusrite_Scarlett_Solo/ &&
    $3 ~ /^[0-9]+$/ && $3 > 0 &&
    $9 ~ /^[0-9]+$/ {
      value = $9
      found = 1
    }
    END {
      if (found) print value
      else exit 1
    }
  '
}

scarlett_xrun_count() {
  timeout 5s pw-top -b -n 6 2>/dev/null | parse_scarlett_xrun_count
}

next_pipewire_quantum_after_xrun() {
  local current="$1"
  [[ "$current" =~ ^[0-9]+$ ]] || { printf '0\n'; return; }
  if (( current <= 256 )); then
    printf '512\n'
  elif (( current <= 512 )); then
    printf '1024\n'
  else
    printf '0\n'
  fi
}

persist_safe_quantum() {
  local value="$1" tmp
  case "$value" in 256|512|1024) ;; *) return 1 ;; esac
  mkdir -p "$(dirname "$SAFE_QUANTUM_FILE")"
  tmp="$SAFE_QUANTUM_FILE.tmp.$$"
  echo "$value" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$SAFE_QUANTUM_FILE"
}

# Monitor only the active Scarlett capture node. One xrun steps the graph up.
# 512 frames is the learned default minimum for this machine; set
# ROARING_MIC_MIN_QUANTUM=256 to explicitly opt into q256 trials.
lower_pipewire_quantum_after_stability() {
  local current="$1" floor="$2"
  [[ -n "$floor" ]] || floor="$MIN_SAFE_QUANTUM"
  [[ "$current" =~ ^[0-9]+$ && "$floor" =~ ^[0-9]+$ ]] || { echo 0; return; }
  if (( current >= 1024 && floor <= 512 )); then
    echo 512
  elif (( current >= 512 && floor <= 256 )); then
    echo 256
  else
    echo 0
  fi
}

wait_for_scarlett_xrun_baseline() {
  local ff="$1" baseline="" attempt
  for attempt in {1..6}; do
    kill -0 "$ff" 2>/dev/null || return 1
    baseline="$(scarlett_xrun_count 2>/dev/null || true)"
    if [[ "$baseline" =~ ^[0-9]+$ ]]; then
      echo "$baseline"
      return 0
    fi
    sleep 2
  done
  return 1
}

watch_pipewire_xruns() {
  local ff="$1" baseline current quantum next stable_since
  baseline="$(wait_for_scarlett_xrun_baseline "$ff" 2>/dev/null || true)"
  if [[ ! "$baseline" =~ ^[0-9]+$ ]]; then
    log "PipeWire xrun monitor unavailable after startup retries; leaving the graph profile unchanged"
    return 0
  fi
  log "PipeWire Scarlett xrun monitor active; baseline ERR=$baseline, minimum graph quantum=$MIN_SAFE_QUANTUM"
  stable_since="$SECONDS"

  while kill -0 "$ff" 2>/dev/null; do
    sleep 5
    kill -0 "$ff" 2>/dev/null || return 0
    current="$(scarlett_xrun_count 2>/dev/null || true)"
    [[ "$current" =~ ^[0-9]+$ ]] || continue
    quantum="$(pipewire_quantum 2>/dev/null || true)"
    [[ "$quantum" =~ ^[0-9]+$ ]] || continue

    if (( current > baseline )); then
      baseline="$current"
      next="$(next_pipewire_quantum_after_xrun "$quantum")"
      stable_since="$SECONDS"
      if (( next > 0 )); then
        log "Scarlett capture xrun count increased at $quantum frames; raising PipeWire graph to $next frames"
        if pw-metadata -n settings 0 clock.force-quantum "$next" >/dev/null 2>&1; then
          persist_safe_quantum "$next" || log "warning: could not persist safe graph quantum $next"
          kill "$ff" 2>/dev/null || true
          return 0
        fi
        log "could not apply fallback quantum $next; preserving current stream"
      else
        persist_safe_quantum "$quantum" || log "warning: could not persist safe graph quantum $quantum"
        log "Scarlett capture xrun observed at maximum $quantum-frame profile; keeping current quantum"
      fi
    elif (( quantum > 256 && SECONDS - stable_since >= 600 )); then
      next="$(lower_pipewire_quantum_after_stability "$quantum" "$MIN_SAFE_QUANTUM")"
      if (( next > 0 )); then
        log "ten minutes xrun-free at $quantum frames; cautiously retrying $next-frame profile (minimum=$MIN_SAFE_QUANTUM)"
        if pw-metadata -n settings 0 clock.force-quantum "$next" >/dev/null 2>&1; then
          persist_safe_quantum "$next" || log "warning: could not persist safe graph quantum $next"
          kill "$ff" 2>/dev/null || true
          return 0
        fi
      fi
      stable_since="$SECONDS"
    fi
  done
}

cap_capture_fragment() {
  if (( PULSE_FRAGMENT_BYTES > PULSE_FRAGMENT_MAX )); then
    log "capping Pulse capture fragment $PULSE_FRAGMENT_BYTES bytes to $PULSE_FRAGMENT_MAX bytes"
    PULSE_FRAGMENT_BYTES="$PULSE_FRAGMENT_MAX"
  fi
}

select_capture_fragment() {
  local quantum=""
  if [[ -n "$PULSE_FRAGMENT_OVERRIDE" ]]; then
    if [[ "$PULSE_FRAGMENT_OVERRIDE" =~ ^[0-9]{1,4}$ ]]; then
      local override_decimal=$((10#$PULSE_FRAGMENT_OVERRIDE))
      if (( override_decimal >= 480 && override_decimal <= PULSE_FRAGMENT_MAX && override_decimal % 2 == 0 )); then
        PULSE_FRAGMENT_BYTES="$override_decimal"
      else
        log "invalid PULSE_FRAGMENT_BYTES override; expected even bytes 480..$PULSE_FRAGMENT_MAX; using auto"
        PULSE_FRAGMENT_OVERRIDE=""
      fi
    else
      log "invalid PULSE_FRAGMENT_BYTES override; expected 1-4 decimal digits; using auto"
      PULSE_FRAGMENT_OVERRIDE=""
    fi
  fi

  quantum="$(pipewire_quantum 2>/dev/null || true)"

  if [[ -z "$PULSE_FRAGMENT_OVERRIDE" && $PULSE_FRAGMENT_FALLBACK -eq 0 ]]; then
    if [[ "$quantum" =~ ^[0-9]+$ ]]; then
      if (( quantum <= 2048 )); then
        # Capture one graph-aware input block. The filter chain splits it into
        # 512-sample PCM frames and paces each frame by PTS before UDP output.
        PULSE_FRAGMENT_BYTES=$(( quantum * 2 ))
        if (( PULSE_FRAGMENT_BYTES < 480 )); then
          PULSE_FRAGMENT_BYTES=480
        fi
      else
        PULSE_FRAGMENT_BYTES=$PULSE_FRAGMENT_MAX
      fi
    else
      quantum="unknown"
      PULSE_FRAGMENT_BYTES=960
    fi
  elif [[ ! "$quantum" =~ ^[0-9]+$ ]]; then
    quantum="unknown"
  fi

  if (( PULSE_FRAGMENT_BYTES > PULSE_FRAGMENT_MAX )); then
    log "capping Pulse capture fragment $PULSE_FRAGMENT_BYTES bytes to supported $PULSE_FRAGMENT_MAX-byte input block"
    PULSE_FRAGMENT_BYTES="$PULSE_FRAGMENT_MAX"
  fi

  local fragment_ms
  fragment_ms="$(awk -v b="$PULSE_FRAGMENT_BYTES" -v r="$RATE" 'BEGIN { printf "%.2f", b*1000/(r*2) }')"
  local quantum_ms="unknown"
  if [[ "$quantum" =~ ^[0-9]+$ ]]; then
    quantum_ms="$(awk -v q="$quantum" -v r="$RATE" 'BEGIN { printf "%.2f", q*1000/r }')"
  fi
  log "capture profile: graph=$quantum frames/$quantum_ms ms, Pulse fragment=$PULSE_FRAGMENT_BYTES bytes/$fragment_ms ms"
}

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
  # Re-check graph timing at each session start. A glitch-triggered larger
  # fragment remains in force until a ten-minute healthy run completes.
  select_capture_fragment

  # Capture from PipeWire/PulseAudio source and stream raw PCM over UDP.
  # Windows side decodes with ffmpeg → VB-Audio Cable Input (see receive_mic.bat).
  # NOTE: -use_wallclock_as_timestamps was removed — it substitutes jittery wall-clock
  # times for PulseAudio timestamps, causing non-monotonic DTS spam that corrupts
  # the UDP stream on the receiver side. aresample corrects clock drift; asetnsamples
  # frames exactly 512 mono samples per datagram, and arealtime paces those frames
  # against their PTS. At a 1024-frame PipeWire graph, this avoids emitting two
  # 1024-byte UDP datagrams back-to-back every 21.33 ms.
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
    -threads 1 \
    -filter_threads 1 \
    -fflags +nobuffer \
    -f pulse \
    -sample_rate "$RATE" \
    -channels "$CHANNELS" \
    -fragment_size "$PULSE_FRAGMENT_BYTES" \
    -i "$MIC_SOURCE" \
    -af aresample=async=1:min_hard_comp=0.1,asetnsamples=n=512:p=0,arealtime \
    -ar "$RATE" \
    -ac "$CHANNELS" \
    -f s16le \
    "udp://${WINDOWS_IP}:${MIC_PORT}?pkt_size=1316" \
    -loglevel error \
    2>"$fifo" &
  local ff=$!

  watch_peer "$ff" &
  local watcher=$!
  watch_pipewire_xruns "$ff" &
  local xrun_watcher=$!

  local glitches=0
  while IFS= read -r line; do
    log "ffmpeg: $line"
    case "$line" in
      *"Failed to compensate for timestamp delta"*)
        glitches=$((glitches + 1))
        if [[ $glitches -ge $GLITCH_LIMIT ]]; then
          if [[ -z "$PULSE_FRAGMENT_OVERRIDE" ]] && (( PULSE_FRAGMENT_BYTES < PULSE_FRAGMENT_MAX )); then
            PULSE_FRAGMENT_BYTES=$(( PULSE_FRAGMENT_BYTES * 2 ))
            cap_capture_fragment
            (( PULSE_FRAGMENT_BYTES > PULSE_FRAGMENT_MAX )) && PULSE_FRAGMENT_BYTES="$PULSE_FRAGMENT_MAX"
            PULSE_FRAGMENT_FALLBACK=1
            log "glitch burst: increasing capture fragment to $PULSE_FRAGMENT_BYTES bytes for the next session"
          fi
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
  kill "$xrun_watcher" 2>/dev/null || true
  wait "$xrun_watcher" 2>/dev/null || true
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
  if (( ran >= 600 && PULSE_FRAGMENT_FALLBACK == 1 )); then
    PULSE_FRAGMENT_FALLBACK=0
    log "ten-minute healthy run: will retry graph-selected low-latency fragment next session"
  fi
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
