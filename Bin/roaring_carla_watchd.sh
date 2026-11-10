#!/usr/bin/env bash
# Re-create only Carla patchbay links authorized by Hearth's mic-router config.
# pw-link -l is used instead of strict JSON parsing because the full graph
# export on this machine contains malformed video-format metadata.
set -euo pipefail

POLL="${CARLA_WATCH_POLL:-10}"
ROUTER_CONF="${ROARING_MIC_ROUTER_CONF:-$HOME/.config/hearth/roaring_mic_router.conf}"
B1_PROCESSED=0
B2_PROCESSED=0

log() { echo "[carla-watch] $(date +'%H:%M:%S') $*"; }

carla_present() {
  pw-cli ls Node 2>/dev/null | grep -q 'node.name = "Carla"'
}

read_router_flag() {
  local key="$1" value
  value="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$ROUTER_CONF" | tail -n1)"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  [[ "${value,,}" == "true" || "${value,,}" == "1" || "${value,,}" == "yes" ]]
}

load_bus_state() {
  [[ -r "$ROUTER_CONF" ]] || return 1
  B1_PROCESSED=0
  B2_PROCESSED=0
  if read_router_flag B1_ACTIVE && read_router_flag CARLA_TO_B1; then
    B1_PROCESSED=1
  fi
  if read_router_flag B2_ACTIVE && read_router_flag CARLA_TO_B2; then
    B2_PROCESSED=1
  fi
}

# has_link OUTNODE OUTPORT INNODE INPORT
#   0 = exact link confirmed present
#   1 = graph queried successfully and link confirmed absent
#   3 = graph query failed/empty and PipeWire unavailable, so no mutation is safe
has_link() {
  local outn="$1" outp="$2" inn="$3" inp="$4"
  local graph=""
  graph="$(pw-link -l 2>/dev/null)" || return 3
  if [[ -z "$graph" ]]; then
    # A successful empty listing means there are currently no links. Confirm
    # that PipeWire itself is queryable before interpreting that as absence.
    pw-cli ls Port >/dev/null 2>&1 || return 3
    return 1
  fi
  printf '%s\n' "$graph" | OUTPORT="${outn}:${outp}" INPORT="${inn}:${inp}" awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^[^[:space:]]/ { current = trim($0); next }
    {
      line = trim($0)
      if (current == ENVIRON["OUTPORT"] && line ~ /^\|->/) {
        sub(/^\|->[[:space:]]*/, "", line)
        if (trim(line) == ENVIRON["INPORT"]) found = 1
      }
      if (current == ENVIRON["INPORT"] && line ~ /^\|<-/) {
        sub(/^\|<-[[:space:]]*/, "", line)
        if (trim(line) == ENVIRON["OUTPORT"]) found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  '
}

ensure_link() {
  local outn="$1" outp="$2" inn="$3" inp="$4"
  local rc=0
  has_link "$outn" "$outp" "$inn" "$inp" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi
  if [[ "$rc" -eq 3 ]]; then
    log "PipeWire graph unavailable -- skipping ${outn}:${outp} -> ${inn}:${inp} this pass"
    return 0
  fi
  if pw-link "${outn}:${outp}" "${inn}:${inp}" 2>/dev/null; then
    log "re-linked ${outn}:${outp} -> ${inn}:${inp}"
  else
    log "failed to link ${outn}:${outp} -> ${inn}:${inp}"
  fi
}

ensure_carla_links() {
  if [[ "$B1_PROCESSED" == "1" || "$B2_PROCESSED" == "1" ]]; then
    ensure_link sm7b_mono capture_MONO Carla audio-in1
    ensure_link sm7b_mono capture_MONO Carla audio-in2
  fi
  if [[ "$B1_PROCESSED" == "1" ]]; then
    ensure_link Carla audio-out1 mic_b1 playback_FL
    ensure_link Carla audio-out2 mic_b1 playback_FR
  fi
  if [[ "$B2_PROCESSED" == "1" ]]; then
    ensure_link Carla audio-out1 mic_b2 playback_FL
    ensure_link Carla audio-out2 mic_b2 playback_FR
  fi
}

main() {
  log "started (poll ${POLL}s, router-config authority, pw-link parser)"
  local was_present=0 last_bus_state=""
  while true; do
    sleep "$POLL"
    if carla_present; then
      if [[ "$was_present" == "0" ]]; then
        log "Carla present -> checking authorized patchbay links"
        was_present=1
      fi
      if load_bus_state; then
        local bus_state="B1=$B1_PROCESSED B2=$B2_PROCESSED"
        if [[ "$bus_state" != "$last_bus_state" ]]; then
          log "Hearth router authorizes $bus_state"
          last_bus_state="$bus_state"
        fi
        ensure_carla_links
      else
        if [[ "$last_bus_state" != "config-missing" ]]; then
          log "router config unavailable; refusing to alter Carla links"
          last_bus_state="config-missing"
        fi
      fi
    elif [[ "$was_present" == "1" ]]; then
      log "Carla went away -> will re-patch authorized links when it returns"
      was_present=0
      last_bus_state=""
    fi
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
