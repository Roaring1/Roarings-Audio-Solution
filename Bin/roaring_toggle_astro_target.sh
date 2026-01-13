#!/usr/bin/env bash

# 10/1/2026-9
# Summary: Toggles ASTRO_TARGET between stereo-chat and stereo-game in roaring_mixer.conf.
#          Does NOT restart routesd (routesd already reloads config in its loop).

# If you paste this into a live terminal, it would run "set -e" etc in your shell.
# Refuse to run in an interactive shell so your terminal doesn't die.
if [[ "$-" == *i* ]]; then
  echo "Don't paste this into the terminal."
  echo "Run it as a file:  bash \"$HOME/bin/roaring_toggle_astro_target.sh\""
  return 0 2>/dev/null || exit 0
fi

set -euo pipefail

CONF="$HOME/.config/roaring_mixer.conf"
chat="alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-chat"
game="alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-game"

mkdir -p "$(dirname "$CONF")"
touch "$CONF"

current="$(grep -E '^ASTRO_TARGET=' "$CONF" | tail -n 1 | sed -E 's/^ASTRO_TARGET="(.*)"/\1/' || true)"

if [[ "$current" == "$game" ]]; then
  next="$chat"
else
  next="$game"
fi

if grep -qE '^ASTRO_TARGET=' "$CONF"; then
  sed -i "s|^ASTRO_TARGET=.*|ASTRO_TARGET=\"$next\"|g" "$CONF"
else
  echo "ASTRO_TARGET=\"$next\"" >> "$CONF"
fi

echo "$next"
