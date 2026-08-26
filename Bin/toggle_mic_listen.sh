#!/usr/bin/env bash
set -euo pipefail

# 9/1/2026-1
# Summary:
# - Toggles monitoring (listening) of B1 or B2 into headphones (Astro target).
# - Uses module-loopback from mic_b{1,2}.monitor -> ASTRO_TARGET.
# - Never routes to speakers; target is ASTRO_TARGET from ~/.config/roaring_mixer.conf.
# 5/13/2026-2  stale-state guard
# Summary: Added listen_is_live() which validates stored module IDs are actually
#          mic_b.monitor loopbacks. IDs recycle after reboot so a stale ID can
#          collide with an unrelated loopback and fool a naive file-exists guard.
#          Stale state auto-restores (re-creates loopback) instead of toggling OFF.

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

# Returns 0 if at least one stored ID is a live module-loopback for $src.
# A plain "does the ID exist" check is NOT enough: module IDs recycle after
# PipeWire restarts, so a stale sidetone ID can collide with an unrelated
# module (e.g. vm_music->stereo-chat) and fool a naive file-exists guard.
listen_is_live() {
  [[ -f "$state" ]] || return 1
  local mods; mods="$(pactl list short modules 2>/dev/null)"
  while read -r id; do
    [[ -n "${id:-}" ]] || continue
    if printf '%s\n' "$mods" | awk -v i="$id" -v s="$src" \
        'BEGIN{found=0} $1==i && $2=="module-loopback" && $0~("source="s){found=1} END{exit !found}'; then
      return 0
    fi
  done < "$state"
  return 1
}

if ! source_exists "$src"; then
  echo "missing source: $src" >&2; exit 1
fi
if ! sink_exists "$ASTRO_TARGET"; then
  echo "missing sink: $ASTRO_TARGET" >&2; exit 1
fi

if listen_is_live; then
  # ON with verified live loopbacks -> toggle OFF
  while read -r id; do
    [[ -n "${id:-}" ]] && pactl unload-module "$id" >/dev/null 2>&1 || true
  done < "$state"
  rm -f "$state"
  echo "listen $want: OFF"
  exit 0
elif [[ -f "$state" ]]; then
  # Stale state (reboot/PW restart) -> clear and fall through to re-create
  rm -f "$state"
fi

# OFF -> turn ON
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