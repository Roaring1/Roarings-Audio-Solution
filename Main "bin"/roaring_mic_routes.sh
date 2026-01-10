#!/usr/bin/env bash
set -euo pipefail

# 9/1/2026-1
# Summary:
# - Ensures remapped mic sources exist:
#     sm7b_mono (Focusrite capture_FL -> mono)
#     astro_mic_48k (Astro mono-chat -> mono 48k)
# - Enforces exact loopbacks into B1/B2:
#     sm7b_mono / astro_mic_48k -> mic_b1 / mic_b2 (based on config)
# - Does NOT touch your VM audio routing or your mic listen loopbacks to Astro.

CONF="$HOME/.config/roaring_mic_router.conf"
LOG="$HOME/.cache/roaring-mic-routesd.log"
mkdir -p "$HOME/.cache"
exec >>"$LOG" 2>&1

log() { echo "[mic-routesd] $(date +%H:%M:%S) $*"; }
wait_for_pactl() { until pactl info >/dev/null 2>&1; do sleep 0.2; done; }

sink_exists()   { pactl list short sinks   2>/dev/null | awk '{print $2}' | grep -qx "$1"; }
source_exists() { pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "$1"; }

load_conf() {
  B1_ROUTE="astro"
  B2_ROUTE="sm7b"
  LATENCY_MSEC="10"
  RATE="48000"
  [[ -f "$CONF" ]] && source "$CONF" || true
}

ensure_sm7b_mono() {
  local master="alsa_input.usb-Focusrite_Scarlett_Solo_USB_Y7XZGYX15C77AB-00.Direct__Direct__source"
  source_exists "sm7b_mono" && return 0
  source_exists "$master" || return 0

  pactl load-module module-remap-source \
    source_name=sm7b_mono \
    master="$master" \
    master_channel_map=front-left \
    channels=1 channel_map=mono remix=no \
    source_properties="device.description=SM7B Mono (L)" >/dev/null 2>&1 || true

  source_exists "sm7b_mono" && log "created source: sm7b_mono" || log "FAILED to create sm7b_mono"
}

ensure_astro_mic_48k() {
  local master="alsa_input.usb-Astro_Gaming_Astro_A50-00.mono-chat"
  source_exists "astro_mic_48k" && return 0
  source_exists "$master" || return 0

  pactl load-module module-remap-source \
    source_name=astro_mic_48k \
    master="$master" \
    rate="$RATE" \
    channels=1 channel_map=mono remix=no \
    source_properties="device.description=Astro Mic (48k)" >/dev/null 2>&1 || true

  source_exists "astro_mic_48k" && log "created source: astro_mic_48k" || log "FAILED to create astro_mic_48k"
}

want_contains() {
  local want="$1" needle="$2"
  [[ "$want" == "$needle" || "$want" == "both" ]]
}

# returns lines of module IDs for mic route loopbacks we manage
list_managed_route_loopbacks() {
  pactl list short modules 2>/dev/null | awk '
    $2=="module-loopback" &&
    ($0 ~ /source=sm7b_mono/ || $0 ~ /source=astro_mic_48k/) &&
    ($0 ~ /sink=mic_b1/ || $0 ~ /sink=mic_b2/)
    {print $1}
  '
}

# returns count for a specific (source,sink) loopback
count_loopback() {
  local src="$1" sink="$2"
  pactl list short modules 2>/dev/null | awk -v s="$src" -v k="$sink" '
    $2=="module-loopback" && $0 ~ ("source=" s) && $0 ~ ("sink=" k) {c++}
    END{print c+0}
  '
}

unload_managed_route_loopbacks() {
  list_managed_route_loopbacks | while read -r id; do
    [[ -n "${id:-}" ]] || continue
    pactl unload-module "$id" >/dev/null 2>&1 || true
  done
}

load_loopback() {
  local src="$1" sink="$2" latency="$3" rate="$4"
  pactl load-module module-loopback \
    source="$src" sink="$sink" \
    latency_msec="$latency" rate="$rate" \
    channels=2 channel_map=front-left,front-right remix=yes \
    source_dont_move=true sink_dont_move=true >/dev/null 2>&1 || true
}

ensure_routes_exact() {
  load_conf

  # prerequisites: buses exist (your busses service already keeps these alive)
  sink_exists "mic_b1" || return 0
  sink_exists "mic_b2" || return 0

  # remapped mic sources
  ensure_sm7b_mono
  ensure_astro_mic_48k

  # Build desired set
  local want_sm7b_b1=0 want_astro_b1=0 want_sm7b_b2=0 want_astro_b2=0
  want_contains "$B1_ROUTE" "sm7b"  && want_sm7b_b1=1
  want_contains "$B1_ROUTE" "astro" && want_astro_b1=1
  want_contains "$B2_ROUTE" "sm7b"  && want_sm7b_b2=1
  want_contains "$B2_ROUTE" "astro" && want_astro_b2=1

  # Check if current set already matches exactly (each desired loopback count ==1 and undesired ==0)
  local ok=1
  [[ "$(count_loopback sm7b_mono mic_b1)"  -eq "$want_sm7b_b1"  ]] || ok=0
  [[ "$(count_loopback astro_mic_48k mic_b1)" -eq "$want_astro_b1" ]] || ok=0
  [[ "$(count_loopback sm7b_mono mic_b2)"  -eq "$want_sm7b_b2"  ]] || ok=0
  [[ "$(count_loopback astro_mic_48k mic_b2)" -eq "$want_astro_b2" ]] || ok=0

  if [[ "$ok" -eq 1 ]]; then
    return 0
  fi

  log "rebuild routes: B1_ROUTE=$B1_ROUTE B2_ROUTE=$B2_ROUTE latency=${LATENCY_MSEC}ms rate=${RATE}"
  unload_managed_route_loopbacks

  if [[ "$want_sm7b_b1" -eq 1 ]]; then load_loopback sm7b_mono mic_b1 "$LATENCY_MSEC" "$RATE"; fi
  if [[ "$want_astro_b1" -eq 1 ]]; then load_loopback astro_mic_48k mic_b1 "$LATENCY_MSEC" "$RATE"; fi
  if [[ "$want_sm7b_b2" -eq 1 ]]; then load_loopback sm7b_mono mic_b2 "$LATENCY_MSEC" "$RATE"; fi
  if [[ "$want_astro_b2" -eq 1 ]]; then load_loopback astro_mic_48k mic_b2 "$LATENCY_MSEC" "$RATE"; fi
}

main() {
  log "starting"
  while true; do
    wait_for_pactl
    ensure_routes_exact || true
    sleep 1
  done
}

main
