#!/usr/bin/env bash
# no_noise_ctl.sh — "No Noise" room-correction toggle, controlled from hearth.
#
# Applies a single tasteful notch (~95Hz, -6dB) to whatever's mirrored out to
# the physical Scarlett speakers, correcting the room resonance measured via
# sweep test (2026-08-06: 16dB peak above ambient floor at ~95Hz).
#
# Runs via PipeWire's filter-chain.service -- a completely separate client
# process from the main pipewire-pulse daemon AND from Carla, so toggling
# this can never trigger a Carla restart, window focus steal, or alt-tab.
#
# Only actually engages while the Scarlett mirror is on (nothing to correct
# with no audio going to the speakers); self-disables the moment the mirror
# goes off, self-re-enables the moment it comes back -- driven by hearth's
# own existing poll loop calling `reconcile` every 0.25-2s (no extra
# background process of our own).
#
# Subcommands:
#   enable      - set preference ON, reconcile immediately
#   disable     - set preference OFF, reconcile immediately
#   reconcile   - bring actual state in line with preference + mirror state
#                 (idempotent, safe to call constantly, this is the default)
#   status      - print current pref/active/mirror state

set -uo pipefail

FOCUSRITE_SINK="alsa_output.usb-Focusrite_Scarlett_Solo_USB_Y7XZGYX15C77AB-00.Direct__Direct__sink"
CFGDIR="$HOME/.config/roaring"
PREF_FILE="$CFGDIR/no_noise.pref"                    # contents: "on" or "off"
ACTIVE_MARK="$HOME/.cache/roaring_no_noise_active"    # exists = actually wired in right now
MIRROR_MARK="$HOME/.cache/roaring_scarlett_loopbacks"
LOG="$HOME/.cache/roaring-no-noise.log"
VM_SOURCES=(vm_game.monitor vm_chat.monitor vm_music.monitor)

mkdir -p "$CFGDIR"
log() { echo "[no-noise] $(date +%H:%M:%S) $*" >> "$LOG"; }
notify() { command -v notify-send >/dev/null 2>&1 && notify-send "Roaring No Noise" "$*"; }

pref_on() { [ -f "$PREF_FILE" ] && [ "$(cat "$PREF_FILE" 2>/dev/null)" = "on" ]; }
mirror_on() { [ -f "$MIRROR_MARK" ]; }
is_active() { [ -f "$ACTIVE_MARK" ]; }

_apply_enable() {
  is_active && return 0
  log "activating"

  systemctl --user is-active --quiet filter-chain.service || systemctl --user start filter-chain.service
  for _ in $(seq 1 20); do
    pactl list short sinks 2>/dev/null | grep -q "no_noise_in" && break
    sleep 0.1
  done
  if ! pactl list short sinks 2>/dev/null | grep -q "no_noise_in"; then
    log "ERROR: no_noise_in never appeared, aborting enable"
    systemctl --user stop filter-chain.service 2>/dev/null || true
    return 1
  fi

  # brief mute to avoid a click while we re-point the loopbacks
  pactl set-sink-mute "$FOCUSRITE_SINK" 1 2>/dev/null || true

  for src in "${VM_SOURCES[@]}"; do
    while IFS= read -r id; do
      [ -n "$id" ] && pactl unload-module "$id" >/dev/null 2>&1
    done < <(pactl list short modules 2>/dev/null | awk -v k="$FOCUSRITE_SINK" \
      -v s="source=$src " '$2=="module-loopback" && index($0,s) && index($0,"sink="k) {print $1}')
    pactl load-module module-loopback source="$src" sink=no_noise_in latency_msec=40 >/dev/null 2>&1
  done

  pw-link no_noise_out:capture_FL "$FOCUSRITE_SINK:playback_FL" >/dev/null 2>&1 || true
  pw-link no_noise_out:capture_FR "$FOCUSRITE_SINK:playback_FR" >/dev/null 2>&1 || true

  sleep 0.15
  pactl set-sink-mute "$FOCUSRITE_SINK" 0 2>/dev/null || true

  touch "$ACTIVE_MARK"
  log "activated"
  notify "Enabled — correcting the ~95Hz room resonance on speaker output."
}

_apply_disable() {
  if ! is_active; then
    systemctl --user is-active --quiet filter-chain.service && systemctl --user stop filter-chain.service
    return 0
  fi
  local restore_direct=0
  mirror_on && restore_direct=1
  log "deactivating (mirror currently $([ "$restore_direct" = 1 ] && echo on || echo off))"

  pactl set-sink-mute "$FOCUSRITE_SINK" 1 2>/dev/null || true

  for src in "${VM_SOURCES[@]}"; do
    while IFS= read -r id; do
      [ -n "$id" ] && pactl unload-module "$id" >/dev/null 2>&1
    done < <(pactl list short modules 2>/dev/null | awk -v s="source=$src " \
      '$2=="module-loopback" && index($0,s) && index($0,"sink=no_noise_in") {print $1}')
    # only restore the plain direct loopback if the mirror is actually still
    # supposed to be on -- if the mirror itself was turned off, leave silent
    if [ "$restore_direct" = 1 ]; then
      pactl load-module module-loopback source="$src" sink="$FOCUSRITE_SINK" latency_msec=40 >/dev/null 2>&1
    fi
  done

  sleep 0.15
  pactl set-sink-mute "$FOCUSRITE_SINK" 0 2>/dev/null || true

  rm -f "$ACTIVE_MARK"
  systemctl --user stop filter-chain.service 2>/dev/null || true
  log "deactivated"
}

cmd="${1:-reconcile}"
case "$cmd" in
  enable)  echo "on"  > "$PREF_FILE" ;;
  disable) echo "off" > "$PREF_FILE" ;;
esac

if pref_on && mirror_on; then
  _apply_enable
else
  _apply_disable
fi

if [ "$cmd" = "status" ]; then
  echo "pref=$(pref_on && echo on || echo off) active=$(is_active && echo yes || echo no) mirror=$(mirror_on && echo yes || echo no)"
fi
