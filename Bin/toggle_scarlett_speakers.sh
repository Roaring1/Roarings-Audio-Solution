#!/usr/bin/env bash
set -euo pipefail

# 9/1/2026-7  scratch-fix
# 8/16/2026   Converted loopback-module mirroring to direct pw-link port
#             connections. Same audio result (PipeWire natively mixes
#             multiple sources into one destination port), but creates
#             ZERO new enumerable PipeWire nodes -- module-loopback used
#             to create 2 bridge nodes per source (6 total for 3 sources),
#             which Vesktop's screenshare "Audio Sources" picker (in
#             Granular Selection mode) then showed as ~18 near-duplicate
#             rows. See roaring-machine SKILL.md section 11.5.
#             Mute-on-load guard timing is UNCHANGED -- still eliminates
#             the wake-from-idle scratch exactly as before.
# Summary: Toggles mirroring VM-GAME/CHAT/MUSIC monitors to Scarlett speakers.
#          Added mute-on-load guard: mutes Scarlett before attaching loopbacks,
#          waits for the DMA buffer to fill with silence, then unmutes.
#          This eliminates the loud scratch when the device wakes from idle.

STATE="$HOME/.cache/roaring_scarlett_loopbacks"
SOURCES=(vm_game vm_chat vm_music)

notify() {
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send "Roaring Scarlett Mirror" "$*"
}

detect_scarlett_sink() {
  pactl list short sinks | awk '{print $2}' | grep -i 'Focusrite\|Scarlett' | head -n 1 || true
}

FOCUSRITE_SINK="$(detect_scarlett_sink)"

if [[ -z "${FOCUSRITE_SINK:-}" ]]; then
  notify "Focusrite sink not found (pactl list short sinks)."
  echo "Focusrite sink not found."
  exit 0
fi

if [[ -f "$STATE" ]]; then
  # --- Turning OFF ---
  for src in "${SOURCES[@]}"; do
    pw-link -d "$src:monitor_FL" "$FOCUSRITE_SINK:playback_FL" >/dev/null 2>&1 || true
    pw-link -d "$src:monitor_FR" "$FOCUSRITE_SINK:playback_FR" >/dev/null 2>&1 || true
  done
  rm -f "$STATE"
  echo "Scarlett speakers mirror: OFF"
  notify "OFF (now only Astro)"
  # let No Noise (if active) clean itself up instantly rather than waiting
  # for hearth's next poll cycle
  "$HOME/bin/no_noise_ctl.sh" reconcile >/dev/null 2>&1 &
else
  # --- Turning ON ---
  # Step 1: mute the Scarlett sink so the wake-up scratch is inaudible
  pactl set-sink-mute "$FOCUSRITE_SINK" 1

  # Step 2: direct pw-link the monitors in (device wakes up here)
  for src in "${SOURCES[@]}"; do
    pw-link "$src:monitor_FL" "$FOCUSRITE_SINK:playback_FL" >/dev/null 2>&1 || true
    pw-link "$src:monitor_FR" "$FOCUSRITE_SINK:playback_FR" >/dev/null 2>&1 || true
  done
  touch "$STATE"

  # Step 3: wait for the DMA buffer to fill with real silence (~250ms is enough)
  sleep 0.25

  # Step 4: unmute — now only clean audio plays through
  pactl set-sink-mute "$FOCUSRITE_SINK" 0

  echo "Scarlett speakers mirror: ON"
  notify "ON (Astro + Scarlett)"
  # let No Noise (if the checkbox was already on) re-engage instantly rather
  # than waiting for hearth's next poll cycle
  "$HOME/bin/no_noise_ctl.sh" reconcile >/dev/null 2>&1 &
fi
