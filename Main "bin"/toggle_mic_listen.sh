#!/usr/bin/env bash
set -euo pipefail

# 9/1/2026-1
# Summary:
# - Toggles monitoring (listening) of B1 or B2 into headphones (Astro target).
# - Uses module-loopback from mic_b{1,2}.monitor -> ASTRO_TARGET.
# - Never routes to speakers; target is ASTRO_TARGET from ~/.config/roaring_mixer.conf.

CONF="$HOME/.config/roaring_mixer.conf"
STATE_DIR="$HOME/.cache/roaring_mic_listen"
mkdir -p "$STATE_DIR"

want="${1:-}"
if [[ "$want" != "b1" && "$want" != "b2" ]]; then
  echo "usage: toggle_mic_listen.sh b1|b2" >&2
  exit 2
fi

ASTRO_TARGET="alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-chat"
LATENCY_MSEC="18"
[[ -f "$CONF" ]] && source "$CONF" || true

src="mic_${want}.monitor"
state="$STATE_DIR/${want}.ids"

sink_exists()   { pactl list short sinks   2>/dev/null | awk '{print $2}' | grep -qx "$1"; }
source_exists() { pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "$1"; }

if ! source_exists "$src"; then
  echo "missing source: $src" >&2
  exit 1
fi
if ! sink_exists "$ASTRO_TARGET"; then
  echo "missing sink: $ASTRO_TARGET" >&2
  exit 1
fi

if [[ -f "$state" ]]; then
  while read -r id; do
    [[ -n "${id:-}" ]] && pactl unload-module "$id" >/dev/null 2>&1 || true
  done < "$state"
  rm -f "$state"
  echo "listen $want: OFF"
  exit 0
fi

: > "$state"
id="$(pactl load-module module-loopback \
  source="$src" sink="$ASTRO_TARGET" \
  latency_msec="$LATENCY_MSEC" rate=48000 channels=2 remix=yes \
  source_dont_move=true sink_dont_move=true 2>/dev/null || true)"

if [[ -n "${id:-}" ]]; then
  echo "$id" >> "$state"
  echo "listen $want: ON  ($src -> $ASTRO_TARGET)"
else
  echo "FAILED to enable listen $want" >&2
  rm -f "$state"
  exit 1
fi
