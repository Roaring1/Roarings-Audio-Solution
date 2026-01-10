#!/usr/bin/env bash
set -euo pipefail

# 9/1/2026-1
# Summary:
# - CLI for routing raw mics into B1/B2 by editing ~/.config/roaring_mic_router.conf
# - Then restarts roaring-mic-routesd.service.
#
# usage:
#   roaring_mic_route.sh b1 none|sm7b|astro|both
#   roaring_mic_route.sh b2 none|sm7b|astro|both
#   roaring_mic_route.sh status

CONF="$HOME/.config/roaring_mic_router.conf"

die(){ echo "$*" >&2; exit 1; }

ensure_conf() {
  [[ -f "$CONF" ]] || cat > "$CONF" <<'EOC'
B1_ROUTE="astro"
B2_ROUTE="sm7b"
LATENCY_MSEC="10"
RATE="48000"
EOC
}

set_key() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$CONF"; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|g" "$CONF"
  else
    echo "${key}=\"${val}\"" >> "$CONF"
  fi
}

ensure_conf

cmd="${1:-}"
if [[ "$cmd" == "status" ]]; then
  echo "== $CONF =="
  sed -n '1,120p' "$CONF"
  echo
  echo "== active mic route loopbacks =="
  pactl list short modules | awk '$2=="module-loopback" && ($0 ~ /source=sm7b_mono|source=astro_mic_48k/) && ($0 ~ /sink=mic_b1|sink=mic_b2/){print}'
  exit 0
fi

bus="${1:-}"; mode="${2:-}"
[[ "$bus" == "b1" || "$bus" == "b2" ]] || die "bus must be b1 or b2"
[[ "$mode" == "none" || "$mode" == "sm7b" || "$mode" == "astro" || "$mode" == "both" ]] || die "mode must be none|sm7b|astro|both"

key="B1_ROUTE"
[[ "$bus" == "b2" ]] && key="B2_ROUTE"

set_key "$key" "$mode"
systemctl --user restart roaring-mic-routesd.service >/dev/null 2>&1 || true

echo "[mic-route] $bus -> $mode"
