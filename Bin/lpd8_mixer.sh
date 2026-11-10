#!/usr/bin/env bash
set -euo pipefail

# 10/1/2026-12
# Summary:
# - LPD8 mixer for PipeWire/Pulse.
# - Coalesces knob events so fast turns always land on the final value (applied at a fixed tick rate).
# - Pads are handled correctly per mode:
#     NOTE mode (latch/toggle): Note ON => state=ON, Note OFF => state=OFF
#                               Note On vel=0 is treated as Note Off (LPD8 firmware variant).
#     PROG mode: Program change is press-only => we maintain internal toggle state per pad.
#     CC mode (pads as CC8..15): value>0 => ON, value==0 => OFF.
# - Pad 1/2 use mute polarity directly: lit = muted; dark = normal/unmuted.
# - Startup toggle state is seeded from the processed B1 and both headset endpoints.
# - The attached classic LPD8 (USB VID:PID 09e8:0075) cannot accept ordinary MIDI Note
#   messages to set LEDs. Its local Note Toggle behavior is configured with editor-only
#   SysEx: pads 1/2 are Toggle (their lights mean muted), pads 3/8 are Momentary (action
#   lights only while pressed), and pads 4-7 are unused. Host changes made outside the pads
#   cannot update the classic unit's physical LEDs.
# - Logs to ~/.cache/lpd8-mixer.log (and prints live when run manually).
# - LEARN=1 prints RAW aseqdump lines + unmapped events.

CONF="$HOME/.config/hearth/roaring_mixer.conf"
LOG="$HOME/.cache/lpd8-mixer.log"
LOCK="$HOME/.cache/lpd8-mixer.lock"
mkdir -p "$HOME/.cache"

# Trim log if it grows
if [[ -f "$LOG" ]] && [[ "$(wc -c < "$LOG")" -gt 1048576 ]]; then
  tail -n 5000 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi

# If running manually in a terminal, show output live + log it.
if [[ -t 1 || -t 2 ]]; then
  exec > >(tee -a "$LOG") 2>&1
else
  exec >>"$LOG" 2>&1
fi

log() { echo "[lpd8] $(date +%H:%M:%S) $*"; }

# single-instance guard
exec 9>"$LOCK"
if command -v flock >/dev/null 2>&1; then
  if ! flock -n 9; then
    log "lock held; another instance is running. exiting."
    exit 0
  fi
fi

LEARN="${LEARN:-0}"
KNOB_MAX=127

# ---- Knob CC mapping ----
CC_VM_MUSIC=4      # k5
CC_VM_CHAT=5       # k6
CC_VM_GAME=6       # k7
CC_MIC_VOL=7       # k8
CC_VM_GAME_ALT=0   # k1

SINK_GAME="vm_game"
SINK_CHAT="vm_chat"
SINK_MUSIC="vm_music"

# The microphone control targets the processed B1 path apps actually use.
# Keep Carla and the physical Scarlett input alive; mute only the B1 bus/feed.
MIC_B1_SINK="mic_b1"
MIC_B1_SOURCE="b1_mic"

# The A50 exposes separate game/chat output endpoints. A headset mute must
# silence both, not only whichever endpoint happens to be the current target.
ASTRO_CHAT_SINK="alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-chat"
ASTRO_GAME_SINK="alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-game"
HEADSET_SINKS=("$ASTRO_CHAT_SINK" "$ASTRO_GAME_SINK")

# ---- NOTE pads (PAD mode) ----
NOTE_PAD1=60
NOTE_PAD2=61
NOTE_PAD3=62
NOTE_PAD4=63
NOTE_PAD5=64
NOTE_PAD6=65
NOTE_PAD7=66
NOTE_PAD8=67

# ---- PROG pads (PROG mode) ----
PROG_1=0
PROG_2=1
PROG_3=2
PROG_4=3
PROG_5=4
PROG_6=5
PROG_7=6
PROG_8=7

# ---- CC pads (CC mode) ----
CC_PAD8=8
CC_PAD1=9
CC_PAD2=10
CC_PAD3=11
CC_PAD4=12
CC_PAD5=13
CC_PAD6=14
CC_PAD7=15

TOGGLE_SCARLETT="$HOME/bin/toggle_scarlett_speakers.sh"

DEBOUNCE_MS=120
IGNORE_PADS_ON_CONNECT_MS=900
_connect_ms=0

MOMENTARY_OFF_MS=220

APPLY_TICK_SEC="0.02"

# ---- LED feedback capability/config ----
# Default OFF for the classic LPD8 (USB VID:PID 09e8:0075), which cannot accept
# incoming MIDI Note messages. Opt in only for a controller verified to support
# host-driven pad LEDs by setting LED_FEEDBACK_SUPPORTED=1 in ~/.config/hearth/roaring_mixer.conf.
LED_FEEDBACK_SUPPORTED=0
# MIDI channel (0-indexed) used for supported devices; channel 10 by default.
MIDI_LED_CHANNEL=9
_lpd8_amidi_port=""   # detected only if LED feedback is explicitly enabled

now_ms() { date +%s%3N; }

wait_for_pactl() { until pactl info >/dev/null 2>&1; do sleep 0.2; done; }

sink_exists() {
  pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$1"
}

source_exists() {
  pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "$1"
}

load_conf() {
  ASTRO_TARGET="alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-chat"
  MIC_SOURCE=""
  LED_FEEDBACK_SUPPORTED=0
  LED_MIDI_CHANNEL=9
  # shellcheck source=/dev/null
  [[ -f "$CONF" ]] && source "$CONF" || true
  MIDI_LED_CHANNEL="${LED_MIDI_CHANNEL:-9}"
}

pads_enabled() {
  local t; t="$(now_ms)"
  (( t - _connect_ms >= IGNORE_PADS_ON_CONNECT_MS ))
}

# Per-pad debounce — each pad has its own last-event timestamp.
# Previously this was a single global scalar; with 8 pads that meant a quick
# press on pad-2 immediately after pad-1 would silently drop pad-2's event.
declare -A _last_pad_ms
pad_debounced() {
  local idx="$1"
  local t; t="$(now_ms)"
  local key="d${idx}"
  local last="${_last_pad_ms[$key]:-0}"
  (( t - last < DEBOUNCE_MS )) && return 1
  _last_pad_ms["$key"]="$t"
  return 0
}

to_pct() {
  local val="$1"
  if (( val >= 124 )); then echo 100; return 0; fi
  if (( val <= 3 ));   then echo 0;   return 0; fi
  local pct=$(( val * 100 / KNOB_MAX ))
  (( pct < 0 ))   && pct=0
  (( pct > 100 )) && pct=100
  echo "$pct"
}

# ----- pactl helpers -----
declare -A _last_set_ms
throttle_ok() {
  local key="$1"
  local t; t="$(now_ms)"
  local last="${_last_set_ms[$key]:-0}"
  (( t - last < 10 )) && return 1
  _last_set_ms["$key"]="$t"
  return 0
}

pactl_set_sink_volume_now() {
  local sink="$1" pct="$2"
  throttle_ok "sink:$sink" || return 0
  pactl set-sink-volume "$sink" "${pct}%" >/dev/null 2>&1 || true
  log "set sink volume: $sink -> ${pct}%"
}

pactl_set_source_volume_now() {
  local src="$1" pct="$2"
  throttle_ok "src:$src" || return 0
  pactl set-source-volume "$src" "${pct}%" >/dev/null 2>&1 || true
  log "set source volume: $src -> ${pct}%"
}

_cached_mic=""
_cached_mic_checked_ms=0
detect_mic_source() {
  if [[ -n "${MIC_SOURCE:-}" ]] && source_exists "$MIC_SOURCE"; then
    echo "$MIC_SOURCE"
    return 0
  fi

  local t; t="$(now_ms)"
  if [[ -n "${_cached_mic:-}" ]] && source_exists "$_cached_mic" && (( t - _cached_mic_checked_ms < 5000 )); then
    echo "$_cached_mic"
    return 0
  fi
  _cached_mic_checked_ms="$t"

  local found=""
  found="$(pactl list short sources 2>/dev/null \
    | awk '{print $2}' \
    | grep -vi '\.monitor$' \
    | grep -Ei 'scarlett|focusrite' \
    | head -n 1 || true)"

  if [[ -n "$found" ]]; then
    _cached_mic="$found"
    echo "$found"
    return 0
  fi

  _cached_mic="@DEFAULT_SOURCE@"
  echo "@DEFAULT_SOURCE@"
}

set_mute_sink() {
  local sink="$1" on="$2" expected state
  if ! sink_exists "$sink"; then
    log "ERROR: mute target sink is missing: $sink"
    return 1
  fi
  if ! pactl set-sink-mute "$sink" "$on" >/dev/null 2>&1; then
    log "ERROR: could not set sink mute: $sink -> $on"
    return 1
  fi
  state="$(pactl get-sink-mute "$sink" 2>/dev/null)" || {
    log "ERROR: could not verify sink mute: $sink"
    return 1
  }
  expected="Mute: $([[ "$on" == "1" || "$on" == "yes" || "$on" == "true" ]] && printf yes || printf no)"
  if [[ "$state" != *"$expected"* ]]; then
    log "ERROR: sink mute verification disagreed: $sink expected $expected, got $state"
    return 1
  fi
  log "verified sink mute=$on: $sink"
}

set_mute_source() {
  local src="$1" on="$2" expected state
  if ! source_exists "$src"; then
    log "ERROR: mute target source is missing: $src"
    return 1
  fi
  if ! pactl set-source-mute "$src" "$on" >/dev/null 2>&1; then
    log "ERROR: could not set source mute: $src -> $on"
    return 1
  fi
  state="$(pactl get-source-mute "$src" 2>/dev/null)" || {
    log "ERROR: could not verify source mute: $src"
    return 1
  }
  expected="Mute: $([[ "$on" == "1" || "$on" == "yes" || "$on" == "true" ]] && printf yes || printf no)"
  if [[ "$state" != *"$expected"* ]]; then
    log "ERROR: source mute verification disagreed: $src expected $expected, got $state"
    return 1
  fi
  log "verified source mute=$on: $src"
}

set_microphone_mute() {
  local on="$1" failed=0
  # Both ends of the processed B1 path are muted together. This never stops
  # the capture/router/Carla services and never mutes the raw Scarlett input.
  set_mute_sink "$MIC_B1_SINK" "$on" || failed=1
  set_mute_source "$MIC_B1_SOURCE" "$on" || failed=1
  (( failed == 0 ))
}

set_headset_mute() {
  local on="$1" sink failed=0
  for sink in "${HEADSET_SINKS[@]}"; do
    if ! set_mute_sink "$sink" "$on"; then
      failed=1
    fi
  done
  (( failed == 0 ))
}

# ============================================================
# LED feedback
# ============================================================

# Find the raw ALSA MIDI port for the LPD8 (used by amidi to WRITE to the device).
detect_lpd8_amidi_port() {
  # Port enumeration can fail during USB reconnect; bound it and return empty
  # so LED initialization can retry instead of wedging or exiting the daemon.
  timeout 2s amidi -l 2>/dev/null | awk '/LPD8/ {print $2; exit}' || true
}

# Set (or clear) the LED on pad <pad_idx> (1-8).
# state=1 → LED on (Note On vel=127)
# state=0 → LED off (Note On vel=0, equivalent to Note Off)
lpd8_led_set() {
  local pad_idx="$1" state="$2"
  # The current classic LPD8 cannot receive MIDI Note feedback. Treat pad LEDs
  # as hardware-managed and avoid futile writes; state initialization is separate.
  [[ "${LED_FEEDBACK_SUPPORTED:-0}" == "1" ]] || return 0
  [[ -z "${_lpd8_amidi_port:-}" ]] && return 1

  local note=$(( 59 + pad_idx ))     # pad 1 = note 60, pad 8 = note 67
  local vel=0; (( state == 1 )) && vel=127
  local st=$(( 0x90 | MIDI_LED_CHANNEL ))   # Note On, configured channel

  # Bound each write so a disappearing USB device cannot wedge the MIDI loop.
  # Return the real result: startup sync must retry failures instead of falsely
  # marking all LEDs initialized after silently discarded amidi errors.
  timeout 1s amidi -p "$_lpd8_amidi_port" \
    -S "$(printf '%02X %02X %02X' "$st" "$note" "$vel")" \
    >/dev/null 2>&1
}

# For action pads: flash the LED on briefly, then off after 350 ms.
# Runs the off-send in a short background subshell so it doesn't block the event loop.
lpd8_led_flash() {
  local pad_idx="$1"
  # Do not spawn a delayed OFF write for hardware that cannot accept feedback.
  [[ "${LED_FEEDBACK_SUPPORTED:-0}" == "1" ]] || return 0
  lpd8_led_set "$pad_idx" 1 || true
  ( sleep 0.35; lpd8_led_set "$pad_idx" 0 || true ) &
}

# Read actual PulseAudio mute state and push the matching LED state to the LPD8.
# Called once after the connect guard expires so the LEDs reflect reality from boot.
# Also pre-seeds the internal _cc_pad_state / _prog_toggle_state arrays so the
# software toggle state matches the hardware LED after the sync.
# Rate-limit retry logs while continuing to retry failed startup/reconnect syncs.
LED_SYNC_LAST_LOG_MS=0
log_led_sync_retry() {
  local reason="$1" now
  now="$(now_ms)"
  if (( now - LED_SYNC_LAST_LOG_MS >= 5000 )); then
    log "LED sync pending: $reason; will retry"
    LED_SYNC_LAST_LOG_MS="$now"
  fi
}

# Read actual mute state and initialize the LPD8 on every connection. A failed
# probe/write returns failure so run_port_loop keeps retrying instead of
# treating a no-port/timeout as a completed sync.
sync_leds_to_pulse_state() {
  load_conf
  if [[ "$LED_FEEDBACK_SUPPORTED" == "1" ]]; then
    _lpd8_amidi_port="$(detect_lpd8_amidi_port)" || _lpd8_amidi_port=""
    if [[ -z "${_lpd8_amidi_port:-}" ]]; then
      log_led_sync_retry "raw amidi port unavailable"
      return 1
    fi
  else
    _lpd8_amidi_port=""
  fi

  # Return 1 for muted and 0 for normal/unmuted. This matches the pad latch:
  # lit = muted; dark = normal.
  _sink_muted_state() {
    local status
    status="$(pactl get-sink-mute "$1" 2>/dev/null)" || return 1
    case "$status" in
      *"Mute: yes"*) printf '1' ;;
      *"Mute: no"*)  printf '0' ;;
      *) return 1 ;;
    esac
  }
  _source_muted_state() {
    local status
    status="$(pactl get-source-mute "$1" 2>/dev/null)" || return 1
    case "$status" in
      *"Mute: yes"*) printf '1' ;;
      *"Mute: no"*)  printf '0' ;;
      *) return 1 ;;
    esac
  }

  local mic_sink mic_source chat game mic headset
  if ! mic_sink=$(_sink_muted_state "$MIC_B1_SINK"); then
    log_led_sync_retry "could not read processed microphone bus mute state"
    return 1
  fi
  if ! mic_source=$(_source_muted_state "$MIC_B1_SOURCE"); then
    log_led_sync_retry "could not read processed microphone source mute state"
    return 1
  fi
  # Fail-safe indication: if either half of B1 is muted, the mic pad is lit.
  mic=0
  if [[ "$mic_sink" == "1" || "$mic_source" == "1" ]]; then mic=1; fi

  if ! chat=$(_sink_muted_state "$ASTRO_CHAT_SINK"); then
    log_led_sync_retry "could not read headset chat endpoint mute state"
    return 1
  fi
  if ! game=$(_sink_muted_state "$ASTRO_GAME_SINK"); then
    log_led_sync_retry "could not read headset game endpoint mute state"
    return 1
  fi
  # Either muted output is a warning; the pad operation itself toggles both.
  headset=0
  if [[ "$chat" == "1" || "$game" == "1" ]]; then headset=1; fi

  # Only send hardware LED feedback if explicitly enabled for a compatible
  # controller. The original/classic LPD8 cannot receive these Note writes.
  if [[ "$LED_FEEDBACK_SUPPORTED" == "1" ]]; then
    local spec pad state
    for spec in "1:$mic" "2:$headset" "3:0" "4:0" "5:0" "6:0" "7:0" "8:0"; do
      pad="${spec%%:*}"
      state="${spec#*:}"
      if ! lpd8_led_set "$pad" "$state"; then
        _lpd8_amidi_port=""
        log_led_sync_retry "MIDI write failed on pad $pad"
        return 1
      fi
    done
  fi

  # Seed software-side toggle mode with mute polarity. The classic LPD8's
  # local Note-mode latch cannot be rewritten remotely; boot defaults ensure
  # both mute targets start unmuted so its fresh, dark pads mean normal.
  _cc_pad_state["p1"]="$mic";     _prog_toggle_state["p1"]="$mic"
  _cc_pad_state["p2"]="$headset"; _prog_toggle_state["p2"]="$headset"

  LED_SYNC_LAST_LOG_MS=0
  if [[ "$LED_FEEDBACK_SUPPORTED" == "1" ]]; then
    log "pad state initialized: mic_muted=$mic headset_muted=$headset (action/unused pads dark)"
  else
    log "pad state initialized: mic_muted=$mic headset_muted=$headset; classic LPD8 uses its local latch (lit=muted, dark=normal)"
  fi
  return 0
}

# ============================================================
# Pad action dispatch
# ============================================================

# idx: 1..8, state: 1=ON (LED lit), 0=OFF (LED dark)
handle_pad_index_state() {
  local idx="$1" state="$2"

  pads_enabled || { (( LEARN == 1 )) && log "pad ignored (startup guard) idx=$idx"; return 0; }
  pad_debounced "$idx" || return 0
  load_conf

  local mute_state="$state"   # LED on = muted; LED off = normal/unmuted

  case "$idx" in
    # Pad 1: processed B1 microphone. Keep capture and Carla running.
    1)
      set_microphone_mute "$mute_state"
      lpd8_led_set 1 "$state" || true
      ;;
    # Pad 2: the complete headset, across both game and chat endpoints.
    2)
      set_headset_mute "$mute_state"
      lpd8_led_set 2 "$state" || true
      ;;
    # Pad 3: one-shot show/focus. It never represents a persistent state.
    3)
      (( state == 1 )) || return 0
      lpd8_led_flash 3
      if [[ -x "$HOME/.local/bin/hearth" ]]; then
        "$HOME/.local/bin/hearth" --show >/dev/null 2>&1 &
        log "Hearth show requested"
      else
        log "Hearth command missing: $HOME/.local/bin/hearth"
      fi
      ;;
    # Pads 4-7 are intentionally unassigned.
    8)
      (( state == 1 )) || return 0
      lpd8_led_flash 8
      if [[ -x "$TOGGLE_SCARLETT" ]]; then
        "$TOGGLE_SCARLETT" || log "toggle scarlett script failed: $TOGGLE_SCARLETT"
      else
        log "toggle scarlett script missing: $TOGGLE_SCARLETT"
      fi
      ;;
    *) : ;;
  esac
}

# ============================================================
# Note / CC / Prog index helpers
# ============================================================

note_to_pad_idx() {
  local note="$1"
  case "$note" in
    "$NOTE_PAD1") echo 1 ;;
    "$NOTE_PAD2") echo 2 ;;
    "$NOTE_PAD3") echo 3 ;;
    "$NOTE_PAD4") echo 4 ;;
    "$NOTE_PAD5") echo 5 ;;
    "$NOTE_PAD6") echo 6 ;;
    "$NOTE_PAD7") echo 7 ;;
    "$NOTE_PAD8") echo 8 ;;
    *) echo 0 ;;
  esac
}

prog_to_pad_idx() {
  local prog="$1"
  case "$prog" in
    "$PROG_1") echo 1 ;;
    "$PROG_2") echo 2 ;;
    "$PROG_3") echo 3 ;;
    "$PROG_4") echo 4 ;;
    "$PROG_5") echo 5 ;;
    "$PROG_6") echo 6 ;;
    "$PROG_7") echo 7 ;;
    "$PROG_8") echo 8 ;;
    *) echo 0 ;;
  esac
}

cc_to_pad_idx_fixed() {
  local cc="$1"
  case "$cc" in
    "$CC_PAD1") echo 1 ;;
    "$CC_PAD2") echo 2 ;;
    "$CC_PAD3") echo 3 ;;
    "$CC_PAD4") echo 4 ;;
    "$CC_PAD5") echo 5 ;;
    "$CC_PAD6") echo 6 ;;
    "$CC_PAD7") echo 7 ;;
    "$CC_PAD8") echo 8 ;;
    *) echo 0 ;;
  esac
}

# ============================================================
# State
# ============================================================

declare -A _pending_sink_pct
declare -A _applied_sink_pct
_pending_mic_pct=""
_applied_mic_pct=""

declare -A _last_note_on_ms
declare -A _prog_toggle_state
declare -A _cc_pad_state

apply_pending_once() {
  for sink in "${!_pending_sink_pct[@]}"; do
    local pct="${_pending_sink_pct[$sink]}"
    local last="${_applied_sink_pct[$sink]:-}"
    if [[ "$pct" != "$last" ]]; then
      pactl_set_sink_volume_now "$sink" "$pct"
      _applied_sink_pct["$sink"]="$pct"
    fi
  done

  if [[ -n "${_pending_mic_pct:-}" ]] && [[ "${_pending_mic_pct:-}" != "${_applied_mic_pct:-}" ]]; then
    load_conf
    local mic; mic="$(detect_mic_source)"
    pactl_set_source_volume_now "$mic" "$_pending_mic_pct"
    _applied_mic_pct="$_pending_mic_pct"
  fi
}

# ============================================================
# Note-Off shared handler. Pads 1/2 are hardware toggles: their next Note Off
# means the second press and therefore unmute. Pads 3/8 are momentary actions;
# their Note Off is only a release and must never fire the action a second time.
# ============================================================

handle_note_off_event() {
  local note="$1"
  local idx; idx="$(note_to_pad_idx "$note")"
  (( idx > 0 )) || return 0
  if [[ "$idx" == "3" || "$idx" == "8" ]]; then
    (( LEARN == 1 )) && log "momentary action pad release ignored idx=$idx"
    return 0
  fi

  local t_now; t_now="$(now_ms)"
  local t_on="${_last_note_on_ms["n${note}"]:-0}"
  local dt=$(( t_now - t_on ))

  # Ignore the immediate release that follows a momentary press.
  # In TOGGLE mode the off comes on the NEXT press (dt >> MOMENTARY_OFF_MS).
  if (( dt > 0 && dt < MOMENTARY_OFF_MS )); then
    (( LEARN == 1 )) && log "note_off ignored (momentary) note=$note dt=${dt}ms"
    return 0
  fi

  handle_pad_index_state "$idx" 0
}

# ============================================================
# Main MIDI event handler
# ============================================================

handle_line() {
  local line="$1"
  (( LEARN == 1 )) && log "RAW: $line"

  # ── Control Change (knobs OR CC pads) ───────────────────────────────────
  if [[ "$line" =~ Control\ change ]] && [[ "$line" =~ controller[[:space:]]+([0-9]+),[[:space:]]+value[[:space:]]+([0-9]+) ]]; then
    local cc="${BASH_REMATCH[1]}"
    local val="${BASH_REMATCH[2]}"

    # A) CC pads (8..15)
    local pidx
    pidx="$(cc_to_pad_idx_fixed "$cc")"
    if (( pidx > 0 )); then
      local now=0
      (( val > 0 )) && now=1
      local key="p${pidx}"
      local was="${_cc_pad_state[$key]:-0}"

      _cc_pad_state["$key"]="$now"

      # Only the two mute pads hold state. Action pads are press-only;
      # empty pads 4-7 are ignored rather than pretending to have a job.
      case "$pidx" in
        1|2)
          handle_pad_index_state "$pidx" "$now"
          ;;
        3|8)
          if (( was == 0 && now == 1 )); then
            handle_pad_index_state "$pidx" 1
          fi
          ;;
        *)
          (( LEARN == 1 )) && log "unassigned CC pad ignored idx=$pidx value=$val"
          ;;
      esac
      return 0
    fi

    # B) Knob CCs (coalesced)
    local pct; pct="$(to_pct "$val")"
    case "$cc" in
      "$CC_VM_MUSIC")    _pending_sink_pct["$SINK_MUSIC"]="$pct" ;;
      "$CC_VM_CHAT")     _pending_sink_pct["$SINK_CHAT"]="$pct" ;;
      "$CC_VM_GAME")     _pending_sink_pct["$SINK_GAME"]="$pct" ;;
      "$CC_MIC_VOL")     _pending_mic_pct="$pct" ;;
      "$CC_VM_GAME_ALT") _pending_sink_pct["$SINK_GAME"]="$pct" ;;
      *) (( LEARN == 1 )) && log "unmapped CC=$cc val=$val" ;;
    esac
    return 0
  fi

  # ── Program Change (press-only → internal toggle) ───────────────────────
  if [[ "$line" =~ Program\ change ]] && [[ "$line" =~ program[[:space:]]+([0-9]+) ]]; then
    local prog="${BASH_REMATCH[1]}"
    local idx; idx="$(prog_to_pad_idx "$prog")"
    (( idx > 0 )) || { (( LEARN == 1 )) && log "unmapped program=$prog"; return 0; }

    # One-shot actions fire on each Program Change. Empty pads stay empty.
    case "$idx" in
      3|8)
        handle_pad_index_state "$idx" 1
        return 0
        ;;
      1|2)
        ;;
      *)
        (( LEARN == 1 )) && log "unassigned Program Change pad ignored idx=$idx program=$prog"
        return 0
        ;;
    esac

    local key="p${idx}"
    local was="${_prog_toggle_state[$key]:-0}"
    local now=0; (( was == 0 )) && now=1
    _prog_toggle_state["$key"]="$now"

    handle_pad_index_state "$idx" "$now"
    return 0
  fi

  # ── Note On ──────────────────────────────────────────────────────────────
  if [[ "$line" =~ Note\ on ]] && [[ "$line" =~ note[[:space:]]+([0-9]+) ]]; then
    local note="${BASH_REMATCH[1]}"
    local vel=127
    if [[ "$line" =~ velocity[[:space:]]+([0-9]+) ]]; then vel="${BASH_REMATCH[1]}"; fi

    # Note On with velocity=0 is semantically identical to Note Off.
    # Some LPD8 firmware variants use this form for the toggle-off event.
    # Previously this was silently dropped (state stuck ON, LED OFF → desync).
    if (( vel == 0 )); then
      (( LEARN == 1 )) && log "note_on vel=0 (treating as note_off) note=$note"
      handle_note_off_event "$note"
      return 0
    fi

    local idx; idx="$(note_to_pad_idx "$note")"
    (( idx > 0 )) || { (( LEARN == 1 )) && log "unmapped note_on=$note vel=$vel"; return 0; }

    _last_note_on_ms["n${note}"]="$(now_ms)"
    handle_pad_index_state "$idx" 1
    return 0
  fi

  # ── Note Off ─────────────────────────────────────────────────────────────
  if [[ "$line" =~ Note\ off ]] && [[ "$line" =~ note[[:space:]]+([0-9]+) ]]; then
    local note="${BASH_REMATCH[1]}"
    handle_note_off_event "$note"
    return 0
  fi
}

# ============================================================
# Port detection & reconnect loop
# ============================================================

auto_detect_port_blocking() {
  while true; do
    local p=""
    p="$(aseqdump -l 2>/dev/null | awk '/LPD8/ {print $1; exit}')"
    if [[ -n "${p:-}" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
    sleep 0.25
  done
}

# aseqdump can remain alive after the USB MIDI device is re-enumerated while
# its ALSA subscription has silently disappeared. A PID check alone therefore
# reports a false "connected" state. Confirm that this exact source port has a
# connection to an aseqdump ALSA client before trusting the event stream.
aseqdump_has_lpd8_subscription() {
  local port="$1"
  local source_client="${port%%:*}"
  local source_port="${port##*:}"
  [[ "$source_client" =~ ^[0-9]+$ && "$source_port" =~ ^[0-9]+$ ]] || return 1

  aconnect -l 2>/dev/null | awk \
    -v source_client="$source_client" -v source_port="$source_port" '
      /^client / {
        in_source_client = ($2 == source_client ":")
        in_source_port = 0
        if ($0 ~ /: '\''aseqdump'\''/) {
          id = $2
          sub(/:$/, "", id)
          aseqdump_clients[id] = 1
        }
        next
      }
      in_source_client && /^[[:space:]]*[0-9]+ / {
        in_source_port = ($1 == source_port)
        next
      }
      in_source_port && /Connecting To:/ {
        id = $3
        sub(/:.*/, "", id)
        connected_clients[id] = 1
      }
      END {
        for (id in aseqdump_clients) {
          if (connected_clients[id]) exit 0
        }
        exit 1
      }
    '
}

run_port_loop() {
  local port="$1"

  # The raw MIDI output is only needed for explicitly supported LED feedback.
  load_conf
  if [[ "$LED_FEEDBACK_SUPPORTED" == "1" ]]; then
    _lpd8_amidi_port="$(detect_lpd8_amidi_port)"
    if [[ -n "${_lpd8_amidi_port:-}" ]]; then
      log "LED feedback enabled: amidi port=$_lpd8_amidi_port"
    else
      log "LED feedback enabled but raw amidi port not found; initialization will retry."
    fi
  else
    _lpd8_amidi_port=""
    log "LED feedback disabled: the attached classic LPD8 does not accept incoming MIDI Note messages."
  fi

  coproc ASEQPROC { stdbuf -oL aseqdump -p "$port" 2>/dev/null; }
  local aseq_pid="$!"
  local aseq_fd="${ASEQPROC[0]}"
  trap 'kill "$aseq_pid" 2>/dev/null || true' RETURN

  # Do not claim "connected" just because aseqdump is alive. Verify that ALSA
  # has actually connected the selected hardware port to an aseqdump client.
  local subscription_deadline_ms=$(( $(now_ms) + 2000 ))
  local subscription_ready=0
  while (( $(now_ms) < subscription_deadline_ms )); do
    if aseqdump_has_lpd8_subscription "$port"; then
      subscription_ready=1
      break
    fi
    sleep 0.1
  done
  if (( subscription_ready == 0 )); then
    log "aseqdump did not subscribe to MIDI_PORT=$port; restarting the reader."
    kill "$aseq_pid" 2>/dev/null || true
    return 1
  fi
  log "MIDI subscription verified: $port"
  local last_subscription_check_ms
  last_subscription_check_ms="$(now_ms)"

  local led_synced=0   # true only after every startup LED write succeeds
  local led_sync_retry_ms=0
  LED_SYNC_LAST_LOG_MS=0

  while true; do
    local line=""
    if IFS= read -r -t "$APPLY_TICK_SEC" -u "$aseq_fd" line; then
      handle_line "$line" || true
    else
      if ! kill -0 "$aseq_pid" >/dev/null 2>&1; then
        break
      fi
    fi

    apply_pending_once || true

    # A USB reconnect can leave the old aseqdump PID alive but detached from
    # the hardware. Periodically verify the ALSA subscription and let the
    # outer port loop create a fresh reader if the link has disappeared.
    local subscription_check_now_ms
    subscription_check_now_ms="$(now_ms)"
    if (( subscription_check_now_ms - last_subscription_check_ms >= 2500 )); then
      last_subscription_check_ms="$subscription_check_now_ms"
      if ! aseqdump_has_lpd8_subscription "$port"; then
        log "MIDI subscription lost on $port; reconnecting."
        break
      fi
    fi

    # Initialize internal pad toggle state from PulseAudio; on compatible
    # devices also sync LEDs. Unsupported classic LPD8 hardware is not probed
    # repeatedly for a feedback feature it cannot implement.
    local led_now
    led_now="$(now_ms)"
    if (( led_synced == 0 )) && pads_enabled && (( led_now - led_sync_retry_ms >= 1000 )); then
      led_sync_retry_ms="$led_now"
      if sync_leds_to_pulse_state; then
        led_synced=1
      fi
    fi
  done

  kill "$aseq_pid" 2>/dev/null || true
}

# ============================================================
# Main
# ============================================================

main() {
  log "starting... LEARN=$LEARN"
  wait_for_pactl

  until sink_exists "$SINK_GAME" && sink_exists "$SINK_CHAT" && sink_exists "$SINK_MUSIC"; do
    log "waiting for VM sinks..."
    sleep 0.4
  done

  load_conf
  until sink_exists "$ASTRO_TARGET"; do
    log "waiting for ASTRO_TARGET=$ASTRO_TARGET"
    sleep 0.4
    load_conf
  done

  log "ready. ASTRO_TARGET=$ASTRO_TARGET | mic=$(detect_mic_source)"

  while true; do
    local port
    port="$(auto_detect_port_blocking)"
    _connect_ms="$(now_ms)"
    log "connected: MIDI_PORT=$port (pads guard ${IGNORE_PADS_ON_CONNECT_MS}ms)"

    run_port_loop "$port" || true

    log "aseqdump ended; reconnecting..."
    sleep 1
  done
}

main
