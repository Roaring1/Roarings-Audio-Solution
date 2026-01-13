#!/usr/bin/env bash
set -euo pipefail

# 9/1/2026-2
# Summary: Toggles mirroring VM-GAME/CHAT/MUSIC monitors to Scarlett speakers via module-loopback.

STATE="$HOME/.cache/roaring_scarlett_loopbacks"

# If state exists but modules are gone (pipewire restart), drop stale state
if [[ -f "$STATE" ]]; then
  if ! pactl list short modules 2>/dev/null | awk '{print $1}' | grep -qf "$STATE"; then
    rm -f "$STATE"
  fi
fi

notify() {
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send "Roaring Scarlett Mirror" "$*"
}

# Auto-detect the Focusrite sink name (safer than hardcoding)
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
  while read -r id; do
    [[ -n "${id:-}" ]] && pactl unload-module "$id" >/dev/null 2>&1 || true
  done < "$STATE"
  rm -f "$STATE"
  echo "Scarlett speakers mirror: OFF"
  notify "OFF (now only Astro)"
else
  : > "$STATE"
  for src in vm_game.monitor vm_chat.monitor vm_music.monitor; do
    id="$(pactl load-module module-loopback source="$src" sink="$FOCUSRITE_SINK" latency_msec=40)"
    echo "$id" >> "$STATE"
  done
  echo "Scarlett speakers mirror: ON"
  notify "ON (Astro + Scarlett)"
fi
