#!/usr/bin/env bash
set -euo pipefail

# 10/1/2026-11
# Summary:
# - LPD8 mixer for PipeWire/Pulse.
# - Coalesces knob events so fast turns always land on the final value (applied at a fixed tick rate).
# - Pads are handled correctly per mode:
#     NOTE mode (latch): Note ON => state=ON, Note OFF => state=OFF (mutes follow state; actions fire on ON only)
#     PROG mode: Program change is press-only => we maintain internal toggle state per pad
#     CC mode (pads as CC8..15): value>0 => ON, value==0 => OFF (actions fire on ON edge only)
# - Logs to ~/.cache/lpd8-mixer.log (and prints live when run manually).
# - LEARN=1 prints RAW aseqdump lines + unmapped events.

CONF="$HOME/.config/roaring_mixer.conf"
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

# single-instance guard (best practice)
exec 9>"$LOCK"
if command -v flock >/dev/null 2>&1; then
  if ! flock -n 9; then
    log "lock held; another instance is running. exiting."
    exit 0
  fi
fi

LEARN="${LEARN:-0}"
KNOB_MAX=127

# ---- Knob CC mapping (your working setup) ----
CC_VM_MUSIC=4      # k5
CC_VM_CHAT=5       # k6
CC_VM_GAME=6       # k7
CC_MIC_VOL=7       # k8
CC_VM_GAME_ALT=0   # k1

SINK_GAME="vm_game"
SINK_CHAT="vm_chat"
SINK_MUSIC="vm_music"

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
# Your physical mapping from your logs:
# pad1..pad7 => CC9..CC15, pad8 => CC8
CC_PAD8=8
CC_PAD1=9
CC_PAD2=10
CC_PAD3=11
CC_PAD4=12
CC_PAD5=13
CC_PAD6=14
CC_PAD7=15

TOGGLE_SCARLETT="$HOME/bin/toggle_scarlett_speakers.sh"
TOGGLE_ASTRO="$HOME/bin/roaring_toggle_astro_target.sh"
DUMP_SCRIPT="$HOME/bin/roaring_audio_debug_dump.sh"

DEBOUNCE_MS=120
IGNORE_PADS_ON_CONNECT_MS=900
_last_pad_ms=0
_connect_ms=0

# If you ever run momentary NOTE pads, Note OFF comes immediately.
# If you're latched (your case), Note OFF comes on the *next press*.
# Ignore “immediate release” offs.
MOMENTARY_OFF_MS=220

# apply tick (seconds). 0.02 => 50Hz
APPLY_TICK_SEC="0.02"

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
  MIC_SOURCE=""  # optional override in conf
  [[ -f "$CONF" ]] && source "$CONF" || true
}

pads_enabled() {
  local t; t="$(now_ms)"
  (( t - _connect_ms >= IGNORE_PADS_ON_CONNECT_MS ))
}

pad_debounced() {
  local t; t="$(now_ms)"
  (( t - _last_pad_ms < DEBOUNCE_MS )) && return 1
  _last_pad_ms="$t"
  return 0
}

to_pct() {
  local val="$1"
  if (( val >= 124 )); then echo 100; return 0; fi
  if (( val <= 3 )); then echo 0; return 0; fi
  local pct=$(( val * 100 / KNOB_MAX ))
  (( pct < 0 )) && pct=0
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
  local sink="$1" on="$2" # on=1 mute, on=0 unmute
  pactl set-sink-mute "$sink" "$on" >/dev/null 2>&1 || true
  log "set mute sink=$sink -> $on"
}

set_mute_source() {
  local src="$1" on="$2"
  pactl set-source-mute "$src" "$on" >/dev/null 2>&1 || true
  log "set mute source=$src -> $on"
}

# idx: 1..8, state: 1=ON, 0=OFF
handle_pad_index_state() {
  local idx="$1" state="$2"

  pads_enabled || { (( LEARN == 1 )) && log "pad ignored (startup guard) idx=$idx"; return 0; }
  pad_debounced || return 0
  load_conf

  # MUTE pads: LED on == channel enabled (unmuted) => invert pactl mute flag.
  local mute_state=$(( 1 - state ))

  case "$idx" in
    # MUTE pads (follow LED/state)
    1) set_mute_sink  "$SINK_MUSIC" "$mute_state" ;;
    2) set_mute_sink  "$SINK_CHAT"  "$mute_state" ;;
    4) set_mute_sink  "$ASTRO_TARGET" "$mute_state" ;;
    6) set_mute_source "$(detect_mic_source)" "$mute_state" ;;
    7) set_mute_sink  "$SINK_GAME" "$mute_state" ;;

    # ACTION pads (fire on ON only)
    3)
      (( state == 1 )) || return 0
      if [[ -x "$TOGGLE_ASTRO" ]]; then
        local n; n="$(bash "$TOGGLE_ASTRO" || true)"
        log "astro target toggled -> ${n:-unknown}"
      else
        log "toggle astro script missing: $TOGGLE_ASTRO"
      fi
      ;;
    5)
      (( state == 1 )) || return 0
      [[ -x "$DUMP_SCRIPT" ]] && "$DUMP_SCRIPT" || log "dump script missing: $DUMP_SCRIPT"
      ;;
    8)
      (( state == 1 )) || return 0
      [[ -x "$TOGGLE_SCARLETT" ]] && "$TOGGLE_SCARLETT" || log "toggle scarlett script missing: $TOGGLE_SCARLETT"
      ;;
    *) : ;;
  esac
}

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

# ---- state ----
declare -A _pending_sink_pct
declare -A _applied_sink_pct
_pending_mic_pct=""
_applied_mic_pct=""

declare -A _last_note_on_ms
declare -A _prog_toggle_state   # PROG pads => internal toggles
declare -A _cc_pad_state        # CC pads => track ON/OFF

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

handle_line() {
  local line="$1"
  (( LEARN == 1 )) && log "RAW: $line"

  # --- Control change (knobs OR CC pads) ---
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

      # mute pads follow state always; action pads fire on rising edge only
      if [[ "$pidx" == "1" || "$pidx" == "2" || "$pidx" == "4" || "$pidx" == "6" || "$pidx" == "7" ]]; then
        handle_pad_index_state "$pidx" "$now"
      else
        if (( was == 0 && now == 1 )); then
          handle_pad_index_state "$pidx" 1
        fi
      fi
      return 0
    fi

    # B) Knob CCs (coalesced)
    local pct; pct="$(to_pct "$val")"
    case "$cc" in
      "$CC_VM_MUSIC") _pending_sink_pct["$SINK_MUSIC"]="$pct" ;;
      "$CC_VM_CHAT")  _pending_sink_pct["$SINK_CHAT"]="$pct" ;;
      "$CC_VM_GAME")  _pending_sink_pct["$SINK_GAME"]="$pct" ;;
      "$CC_MIC_VOL")  _pending_mic_pct="$pct" ;;
      "$CC_VM_GAME_ALT") _pending_sink_pct["$SINK_GAME"]="$pct" ;;
      *) (( LEARN == 1 )) && log "unmapped CC=$cc val=$val" ;;
    esac
    return 0
  fi

  # --- Program change (press-only => internal toggle) ---
  if [[ "$line" =~ Program\ change ]] && [[ "$line" =~ program[[:space:]]+([0-9]+) ]]; then
    local prog="${BASH_REMATCH[1]}"
    local idx; idx="$(prog_to_pad_idx "$prog")"
    (( idx > 0 )) || { (( LEARN == 1 )) && log "unmapped program=$prog"; return 0; }

    # Action pads should fire on every press in PROG mode (not every other).
    if [[ "$idx" == "3" || "$idx" == "5" || "$idx" == "8" ]]; then
      handle_pad_index_state "$idx" 1
      return 0
    fi

    local key="p${idx}"
    local was="${_prog_toggle_state[$key]:-0}"
    local now=0
    (( was == 0 )) && now=1
    _prog_toggle_state["$key"]="$now"

    handle_pad_index_state "$idx" "$now"
    return 0
  fi

  # --- Note ON (NOTE mode) ---
  if [[ "$line" =~ Note\ on ]] && [[ "$line" =~ note[[:space:]]+([0-9]+) ]]; then
    local note="${BASH_REMATCH[1]}"
    local vel="127"
    if [[ "$line" =~ velocity[[:space:]]+([0-9]+) ]]; then
      vel="${BASH_REMATCH[1]}"
    fi
    (( vel == 0 )) && return 0

    local idx; idx="$(note_to_pad_idx "$note")"
    (( idx > 0 )) || { (( LEARN == 1 )) && log "unmapped note_on=$note vel=$vel"; return 0; }

    _last_note_on_ms["n${note}"]="$(now_ms)"
    handle_pad_index_state "$idx" 1
    return 0
  fi

  # --- Note OFF (NOTE mode latch OFF) ---
  if [[ "$line" =~ Note\ off ]] && [[ "$line" =~ note[[:space:]]+([0-9]+) ]]; then
    local note="${BASH_REMATCH[1]}"
    local idx; idx="$(note_to_pad_idx "$note")"
    (( idx > 0 )) || return 0

    local t_now; t_now="$(now_ms)"
    local t_on="${_last_note_on_ms["n${note}"]:-0}"
    local dt=$(( t_now - t_on ))

    # If this was a momentary-release (off came instantly), ignore.
    if (( dt > 0 && dt < MOMENTARY_OFF_MS )); then
      (( LEARN == 1 )) && log "note_off ignored (momentary) note=$note dt=${dt}ms"
      return 0
    fi

    if [[ "$idx" == "3" || "$idx" == "8" ]]; then
      handle_pad_index_state "$idx" 1
    elif [[ "$idx" == "5" ]]; then
      # Dump only on note_on (avoid duplicates on note_off).
      return 0
    else
      handle_pad_index_state "$idx" 0
    fi
    return 0
  fi
}

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

run_port_loop() {
  local port="$1"

  # Start aseqdump as a coprocess so we can:
  # - read with -t ticks (no background apply loop)
  # - detect when aseqdump dies and reconnect cleanly
  coproc ASEQPROC { stdbuf -oL aseqdump -p "$port" 2>/dev/null; }
  local aseq_pid="$!"
  local aseq_fd="${ASEQPROC[0]}"

  # ensure we kill it if we leave
  trap 'kill "$aseq_pid" 2>/dev/null || true' RETURN

  while true; do
    local line=""
    if IFS= read -r -t "$APPLY_TICK_SEC" -u "$aseq_fd" line; then
      handle_line "$line" || true
    else
      # timeout OR EOF; if aseqdump died, break to reconnect
      if ! kill -0 "$aseq_pid" >/dev/null 2>&1; then
        break
      fi
    fi

    apply_pending_once || true
  done

  kill "$aseq_pid" 2>/dev/null || true
}

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
