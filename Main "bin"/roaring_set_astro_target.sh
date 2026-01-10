#!/usr/bin/env bash
set -euo pipefail

# 9/1/2026-5
# Summary: Sets Astro target sink to CHAT or GAME (persisted), then restarts routing service.

CFG_DIR="$HOME/.config/roaring_audio"
CFG_FILE="$CFG_DIR/astro_target"
mkdir -p "$CFG_DIR"

ASTRO_GAME="alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-game"
ASTRO_CHAT="alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-chat"

mode="${1:-}"
if [[ -z "$mode" ]]; then
  echo "usage: roaring_set_astro_target.sh chat|game|toggle" >&2
  exit 2
fi

current="$(cat "$CFG_FILE" 2>/dev/null || true)"

case "$mode" in
  chat)   target="$ASTRO_CHAT" ;;
  game)   target="$ASTRO_GAME" ;;
  toggle)
    if [[ "$current" == "$ASTRO_CHAT" ]]; then target="$ASTRO_GAME"; else target="$ASTRO_CHAT"; fi
    ;;
  *)
    echo "usage: roaring_set_astro_target.sh chat|game|toggle" >&2
    exit 2
    ;;
esac

echo "$target" > "$CFG_FILE"
echo "[astro] target set to: $target"

systemctl --user restart roaring-audio-routesd.service >/dev/null 2>&1 || true
systemctl --user restart lpd8-mixer.service >/dev/null 2>&1 || true
