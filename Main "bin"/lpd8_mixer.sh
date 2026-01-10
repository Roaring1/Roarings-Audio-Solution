#!/usr/bin/env bash
set -euo pipefail

# 9/1/2026-8
# Summary:
# - LPD8 mixer for PipeWire/Pulse.
# - Knobs (CC):
#     CC4  (k5) -> vm_music
#     CC5  (k6) -> vm_chat
#     CC6  (k7) -> vm_game
#     CC7  (k8) -> Scarlett mic source volume (auto-detect Focusrite/Scarlett; fallback @DEFAULT_SOURCE@)
#     CC0  (k1) -> vm_game (your unit currently doesn't send CC0; harmless to keep)
#   CC1-CC3 ignored (k2-k4 = nothing).
#
# - Pads:
#   PAD mode: Note on/off notes 60..67 (either edge triggers once with debounce).
#   PROG mode: Program change 0..7 (still supported).
#
# - Actions (pad index 1..8):
#   1 mute vm_music, 2 mute vm_chat, 3 toggle astro target, 4 dump,
#   5 mute astro target, 6 mute mic, 7 mute vm_game, 8 toggle scarlett mirror
#
# - Logs to ~/.cache/lpd8-mixer.log, and also prints live when run manually in a terminal.
# - LEARN=1 prints RAW aseqdump lines + unmapped events.

CONF="$HOME/.config/roaring_mixer.conf"
LOG="$HOME/.cache/lpd8-mixer.log"
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

LEARN="${LEARN:-0}"
KNOB_MAX=127

# --- CC mapping (your requested layout) ---
CC_VM_MUSIC=4   # k5
CC_VM_CHAT=5    # k6
CC_VM_GAME=6    # k7
CC_MIC_VOL=7    # k8
CC_VM_GAME_ALT=0  # k1 (not currently sending on your unit)

SINK_GAME="vm_game"
SINK_CHAT="vm_chat"
SINK_MUSIC="vm_music"

# PAD notes (PAD mode)
NOTE_PAD1=60
NOTE_PAD2=61
NOTE_PAD3=62
NOTE_PAD4=63
NOTE_PAD5=64
NOTE_PAD6=65
NOTE_PAD7=66
NOTE_PAD8=67

# Program change numbers (PROG mode; still supported)
PROG_1=0
PROG_2=1
PROG_3=2
PROG_4=3
PROG_5=4
PROG_6=5
PROG_7=6
PROG_8=7

TOGGLE_SCARLETT="$HOME/bin/toggle_scarlett_speakers.sh"
TOGGLE_ASTRO="$HOME/bin/roaring_toggle_astro_target.sh"
DUMP_SCRIPT="$HOME/bin/roaring_audio_dump.sh"

DEBOUNCE_MS=140
IGNORE_PADS_ON_CONNECT_MS=900
_last_pad_ms=0
_connect_ms=0

declare -A _last_set_ms
_cached_mic=""
_cached_mic_checked_ms=0

now_ms() { date +%s%3N; }

to_pct() {
  local val="$1"
  local pct=$(( val * 100 / KNOB_MAX ))
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  echo "$pct"
}

wait_for_pactl() { until pactl info >/dev/null 2>&1; do sleep 0.2; done; }

sink_exists() {
  local s="$1"
  pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$s"
}

source_exists() {
  local s="$1"
  pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "$s"
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

throttle_ok() {
  local key="$1"
  local t; t="$(now_ms)"
  local last="${_last_set_ms[$key]:-0}"
  # ~25ms feels immediate but avoids absurd pactl spam.
  if (( t - last < 25 )); then
    return 1
  fi
  _last_set_ms["$key"]="$t"
  return 0
}

pactl_set_sink_volume() {
  local sink="$1" pct="$2"
  throttle_ok "sink:$sink" || return 0
  pactl set-sink-volume "$sink" "${pct}%" >/dev/null 2>&1 || true
  log "set sink volume: $sink -> ${pct}%"
}

pactl_set_source_volume() {
  local src="$1" pct="$2"
  throttle_ok "src:$src" || return 0
  pactl set-source-volume "$src" "${pct}%" >/dev/null 2>&1 || true
  log "set source volume: $src -> ${pct}%"
}

detect_mic_source() {
  # Allow explicit override in ~/.config/roaring_mixer.conf:
  #   MIC_SOURCE="alsa_input.usb-Focusrite_Scarlett_Solo_..."
  if [[ -n "${MIC_SOURCE:-}" ]] && source_exists "$MIC_SOURCE"; then
    echo "$MIC_SOURCE"
    return 0
  fi

  # Cache for 5 seconds to avoid repeated scanning while turning knobs.
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

toggle_mute_sink() {
  local sink="$1"
  pactl set-sink-mute "$sink" toggle >/dev/null 2>&1 || true
  log "toggle mute sink=$sink"
}

toggle_mute_source() {
  local src="$1"
  pactl set-source-mute "$src" toggle >/dev/null 2>&1 || true
  log "toggle mute source=$src"
}

handle_pad_index() {
  local idx="$1"

  pads_enabled || { (( LEARN == 1 )) && log "pad ignored (startup guard) idx=$idx"; return 0; }
  pad_debounced || return 0
  load_conf

  case "$idx" in
    1) toggle_mute_sink "$SINK_MUSIC" ;;
    2) toggle_mute_sink "$SINK_CHAT" ;;
    3)
      if [[ -x "$TOGGLE_ASTRO" ]]; then
        local n; n="$(bash "$TOGGLE_ASTRO" || true)"
        log "astro target toggled -> ${n:-unknown}"
      else
        log "toggle astro script missing: $TOGGLE_ASTRO"
      fi
      ;;
    4) [[ -x "$DUMP_SCRIPT" ]] && "$DUMP_SCRIPT" || log "dump script missing: $DUMP_SCRIPT" ;;
    5) toggle_mute_sink "$ASTRO_TARGET" ;;
    6) toggle_mute_source "$(detect_mic_source)" ;;
    7) toggle_mute_sink "$SINK_GAME" ;;
    8) [[ -x "$TOGGLE_SCARLETT" ]] && "$TOGGLE_SCARLETT" || log "toggle scarlett script missing: $TOGGLE_SCARLETT" ;;
    *) : ;;
  esac
}

handle_line() {
  local line="$1"
  (( LEARN == 1 )) && log "RAW: $line"

  # --- Knobs (Control change) ---
  if [[ "$line" =~ Control\ change ]] && [[ "$line" =~ controller[[:space:]]+([0-9]+),[[:space:]]+value[[:space:]]+([0-9]+) ]]; then
    local cc="${BASH_REMATCH[1]}"
    local val="${BASH_REMATCH[2]}"
    local pct; pct="$(to_pct "$val")"

    case "$cc" in
      "$CC_VM_MUSIC") pactl_set_sink_volume "$SINK_MUSIC" "$pct" ;;
      "$CC_VM_CHAT")  pactl_set_sink_volume "$SINK_CHAT"  "$pct" ;;
      "$CC_VM_GAME")  pactl_set_sink_volume "$SINK_GAME"  "$pct" ;;
      "$CC_MIC_VOL")
        local mic; mic="$(detect_mic_source)"
        pactl_set_source_volume "$mic" "$pct"
        ;;
      "$CC_VM_GAME_ALT") pactl_set_sink_volume "$SINK_GAME" "$pct" ;;
      *)
        (( LEARN == 1 )) && log "unmapped CC=$cc val=$val"
        ;;
    esac
    return 0
  fi

  # --- Pads in PROG mode (Program change) ---
  if [[ "$line" =~ Program\ change ]] && [[ "$line" =~ program[[:space:]]+([0-9]+) ]]; then
    local prog="${BASH_REMATCH[1]}"
    case "$prog" in
      "$PROG_1") handle_pad_index 1 ;;
      "$PROG_2") handle_pad_index 2 ;;
      "$PROG_3") handle_pad_index 3 ;;
      "$PROG_4") handle_pad_index 4 ;;
      "$PROG_5") handle_pad_index 5 ;;
      "$PROG_6") handle_pad_index 6 ;;
      "$PROG_7") handle_pad_index 7 ;;
      "$PROG_8") handle_pad_index 8 ;;
      *) (( LEARN == 1 )) && log "unmapped program=$prog" ;;
    esac
    return 0
  fi

  # --- Pads in PAD mode (Note ON only; ignore Note OFF / velocity 0) ---
  if [[ "$line" =~ Note\ on ]] && [[ "$line" =~ note[[:space:]]+([0-9]+) ]]; then
    local note="${BASH_REMATCH[1]}"

    local vel="127"
    if [[ "$line" =~ velocity[[:space:]]+([0-9]+) ]]; then
      vel="${BASH_REMATCH[1]}"
    fi

    # MIDI convention: Note-on with velocity 0 is effectively Note-off.
    (( vel == 0 )) && return 0

    case "$note" in
      "$NOTE_PAD1") handle_pad_index 1 ;;
      "$NOTE_PAD2") handle_pad_index 2 ;;
      "$NOTE_PAD3") handle_pad_index 3 ;;
      "$NOTE_PAD4") handle_pad_index 4 ;;
      "$NOTE_PAD5") handle_pad_index 5 ;;
      "$NOTE_PAD6") handle_pad_index 6 ;;
      "$NOTE_PAD7") handle_pad_index 7 ;;
      "$NOTE_PAD8") handle_pad_index 8 ;;
      *) (( LEARN == 1 )) && log "unmapped note=$note vel=$vel" ;;
    esac
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

main() {
  log "starting... LEARN=$LEARN"
  wait_for_pactl

  # Wait for VM sinks (created by roaring-vm-sinks.service)
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

    while IFS= read -r line; do
      handle_line "$line" || true
    done < <(stdbuf -oL aseqdump -p "$port" 2>/dev/null || true)

    log "aseqdump ended; reconnecting..."
    sleep 1
  done
}

main
