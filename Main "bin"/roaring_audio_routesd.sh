#!/usr/bin/env bash
set -euo pipefail

# 10/1/2026-2
# Summary:
# - Keeps VM audio routed to your Astro target using module-loopback.
# - NEVER unloads modules (PipeWire-Pulse can deny UNLOAD_MODULE and cause thrash).
# - Only ensures the 3 loopbacks exist: vm_game/chat/music.monitor -> ASTRO_TARGET.
# - Auto-detects ASTRO_TARGET if not explicitly set.

LOG="$HOME/.cache/roaring-audio-routesd.log"
mkdir -p "$HOME/.cache"
exec >>"$LOG" 2>&1

LATENCY_MSEC="${LATENCY_MSEC:-40}"
ASTRO_TARGET="${ASTRO_TARGET:-}"          # optional override (sink name)
ASTRO_MATCH_RE="${ASTRO_MATCH_RE:-Astro}" # used only if ASTRO_TARGET is empty

log() { echo "[audio-routesd] $(date +%H:%M:%S) $*"; }

wait_for_pactl() {
  local i=0
  until pactl info >/dev/null 2>&1; do
    ((i++)) || true
    if (( i > 200 )); then
      log "pactl not responding after ~40s; continuing anyway."
      return 0
    fi
    sleep 0.2
  done
}

sink_exists() {
  local name="$1"
  pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$name"
}

find_astro_target() {
  # If user pinned ASTRO_TARGET and it exists, keep it.
  if [[ -n "$ASTRO_TARGET" ]] && sink_exists "$ASTRO_TARGET"; then
    echo "$ASTRO_TARGET"
    return 0
  fi

  # Otherwise try to find by description/name match.
  # We prefer "PipeWire" sinks and anything matching ASTRO_MATCH_RE.
  local target=""
  target="$(
    pactl list short sinks 2>/dev/null | awk '{print $2}'
  )"

  # First pass: match sink NAME
  local by_name=""
  by_name="$(echo "$target" | grep -Ei "$ASTRO_MATCH_RE" | head -n 1 || true)"
  if [[ -n "$by_name" ]]; then
    echo "$by_name"
    return 0
  fi

  # Second pass: match "device.description" from full sink listing
  local by_desc=""
  by_desc="$(
    pactl list sinks 2>/dev/null \
      | awk '
          BEGIN{RS="Sink #"; FS="\n"}
          NR>1{
            name=""; desc=""
            for(i=1;i<=NF;i++){
              if($i ~ /^[[:space:]]*Name:/){ sub(/^[[:space:]]*Name:[[:space:]]*/, "", $i); name=$i }
              if($i ~ /device\.description/){ sub(/.*= "/, "", $i); sub(/".*/, "", $i); desc=$i }
            }
            if(name!="" && desc!=""){
              print name "\t" desc
            }
          }' \
      | grep -Ei "$ASTRO_MATCH_RE" \
      | head -n 1 \
      | awk '{print $1}' \
      || true
  )"

  if [[ -n "$by_desc" ]]; then
    echo "$by_desc"
    return 0
  fi

  echo ""
  return 0
}

loopback_exists() {
  local src="$1" sink="$2"
  pactl list short modules 2>/dev/null \
    | awk '$2=="module-loopback" && $0 ~ ("source=" s) && $0 ~ ("sink=" k) {found=1} END{exit(found?0:1)}' \
      s="$src" k="$sink"
}

ensure_loopback() {
  local src="$1" sink="$2"
  if loopback_exists "$src" "$sink"; then
    return 0
  fi

  pactl load-module module-loopback \
    source="$src" sink="$sink" latency_msec="$LATENCY_MSEC" >/dev/null 2>&1 || true

  if loopback_exists "$src" "$sink"; then
    log "created loopback: source=$src -> sink=$sink (latency=${LATENCY_MSEC}ms)"
  else
    log "FAILED create loopback: source=$src -> sink=$sink"
  fi
}

main() {
  log "starting (LATENCY_MSEC=$LATENCY_MSEC ASTRO_TARGET=${ASTRO_TARGET:-auto} ASTRO_MATCH_RE=$ASTRO_MATCH_RE)"
  while true; do
    wait_for_pactl

    local target=""
    target="$(find_astro_target)"

    if [[ -z "$target" ]]; then
      log "no Astro target detected yet; sleeping..."
      sleep 2
      continue
    fi

    # Ensure loopbacks exist. NO UNLOADS. No thrash.
    ensure_loopback "vm_game.monitor"  "$target"
    ensure_loopback "vm_chat.monitor"  "$target"
    ensure_loopback "vm_music.monitor" "$target"

    sleep 2
  done
}

main
