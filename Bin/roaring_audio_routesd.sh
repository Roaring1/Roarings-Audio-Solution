#!/usr/bin/env bash
set -euo pipefail

# 10/1/2026-2
# Summary:
# - Keeps VM audio routed to your Astro target using module-loopback.
# - Only unloads VM loopbacks when the target changes (best-effort).
# - Ensures the 3 loopbacks exist: vm_game/chat/music.monitor -> ASTRO_TARGET.
# - Auto-detects ASTRO_TARGET if not explicitly set.

LOG="$HOME/.cache/roaring-audio-routesd.log"
mkdir -p "$HOME/.cache"
exec >>"$LOG" 2>&1

CONF="$HOME/.config/roaring_mixer.conf"
STATE_FILE="$HOME/.cache/roaring-audio-routesd.target"

ENV_LATENCY_MSEC="${LATENCY_MSEC:-40}"
ENV_ASTRO_TARGET="${ASTRO_TARGET:-}"          # optional override (sink name)
ENV_ASTRO_MATCH_RE="${ASTRO_MATCH_RE:-Astro}" # used only if ASTRO_TARGET is empty
DEDUP_INTERVAL_SEC=15

log() { echo "[audio-routesd] $(date +%H:%M:%S) $*"; }
now_sec() { date +%s; }

load_conf() {
  LATENCY_MSEC="$ENV_LATENCY_MSEC"
  ASTRO_TARGET="$ENV_ASTRO_TARGET"
  ASTRO_MATCH_RE="$ENV_ASTRO_MATCH_RE"
  if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
  fi
}

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

unload_vm_loopbacks_to_sink() {
  local sink="$1"
  pactl list short modules 2>/dev/null | awk -v k="$sink" '
    $2=="module-loopback" &&
    ($0 ~ /source=vm_game\.monitor/ || $0 ~ /source=vm_chat\.monitor/ || $0 ~ /source=vm_music\.monitor/) &&
    $0 ~ ("sink=" k) {print $1}
  ' | while read -r id; do
    [[ -n "${id:-}" ]] || continue
    pactl unload-module "$id" >/dev/null 2>&1 || true
  done
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

_last_dedupe_sec=0
dedupe_loopbacks_for_target() {
  local target="$1"
  local t; t="$(now_sec)"
  (( t - _last_dedupe_sec < DEDUP_INTERVAL_SEC )) && return 0
  _last_dedupe_sec="$t"

  local src
  for src in vm_game.monitor vm_chat.monitor vm_music.monitor; do
    mapfile -t ids < <(pactl list short modules 2>/dev/null | awk -v s="$src" -v k="$target" '
      $2=="module-loopback" && $0 ~ ("source=" s) && $0 ~ ("sink=" k) {print $1}
    ')
    if (( ${#ids[@]} > 1 )); then
      local keep="${ids[0]}"
      local id
      for id in "${ids[@]:1}"; do
        pactl unload-module "$id" >/dev/null 2>&1 || true
      done
      log "dedupe: kept $keep for $src -> $target (removed $(( ${#ids[@]} - 1 )))"
    fi
  done
}

main() {
  load_conf
  log "starting (LATENCY_MSEC=$LATENCY_MSEC ASTRO_TARGET=${ASTRO_TARGET:-auto} ASTRO_MATCH_RE=$ASTRO_MATCH_RE)"
  while true; do
    wait_for_pactl
    load_conf

    local target=""
    target="$(find_astro_target)"

    if [[ -z "$target" ]]; then
      log "no Astro target detected yet; sleeping..."
      sleep 2
      continue
    fi

    local last=""
    last="$(cat "$STATE_FILE" 2>/dev/null || true)"
    if [[ -n "$last" && "$last" != "$target" ]]; then
      log "target changed: $last -> $target; removing old loopbacks"
      unload_vm_loopbacks_to_sink "$last"
    fi
    if [[ "$last" != "$target" ]]; then
      printf '%s\n' "$target" > "$STATE_FILE"
    fi

    # Ensure loopbacks exist; unload only on target change.
    ensure_loopback "vm_game.monitor"  "$target"
    ensure_loopback "vm_chat.monitor"  "$target"
    ensure_loopback "vm_music.monitor" "$target"
    dedupe_loopbacks_for_target "$target"

    sleep 2
  done
}

main
