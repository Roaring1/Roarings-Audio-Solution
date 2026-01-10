#!/usr/bin/env bash
set -euo pipefail

# 10/1/2026-1
# Summary:
# - Listens to LPD8 MIDI events via aseqdump.
# - On a specific Note-On, triggers roaring_audio_debug_dump.sh.
# - Debounced so you can't spam it accidentally.

TRIGGER_NOTE="${TRIGGER_NOTE:-36}"   # common first pad note; adjust if needed
MIN_GAP_SEC="${MIN_GAP_SEC:-3}"

log() { echo "[lpd8-debug] $(date +%H:%M:%S) $*"; }

find_lpd8_port() {
  # aseqdump -l output varies a bit; this tries to pick first port under a client containing "LPD8"
  aseqdump -l 2>/dev/null | awk '
    BEGIN{client=""}
    /^client [0-9]+:/{
      client=$2; gsub(":","",client)
      name=$0
      next
    }
    /LPD8/i && /^client [0-9]+:/{
      # handled above, but keep for readability
      next
    }
    /LPD8/i { next }
  ' >/dev/null || true

  local client=""
  client="$(aseqdump -l 2>/dev/null | awk '
    /^client [0-9]+:/{
      c=$2; gsub(":","",c)
      line=$0
      if(line ~ /LPD8/i){ print c; exit }
    }')"

  [[ -n "$client" ]] || { echo ""; return 0; }

  local port=""
  port="$(aseqdump -l 2>/dev/null | awk -v c="$client" '
    $1=="client"{
      cc=$2; gsub(":","",cc)
      inClient=(cc==c)
    }
    inClient && $1 ~ /^[0-9]+$/ && $2 ~ /:/{
      # format varies; safer parse: the "port" number is first field when inClient and line starts with spaces+number
      # Example: "  0 'LPD8 MIDI 1'"
      p=$1
      print c ":" p
      exit
    }
  ' | head -n 1)"

  echo "$port"
}

main() {
  if ! command -v aseqdump >/dev/null 2>&1; then
    log "aseqdump not found (package: alsa-utils). exiting."
    exit 1
  fi

  local port=""
  port="$(find_lpd8_port)"

  if [[ -z "$port" ]]; then
    log "LPD8 port not found. Is it plugged in? (try: aseqdump -l)"
    exit 1
  fi

  log "listening on port=$port trigger_note=$TRIGGER_NOTE"

  local last=0
  stdbuf -oL aseqdump -p "$port" 2>/dev/null | while read -r line; do
    # Match Note on lines and extract note/velocity.
    # Typical aseqdump line contains: "Note on                0, note 36, velocity 127"
    if echo "$line" | grep -q "Note on"; then
      local note vel now
      note="$(echo "$line" | sed -n 's/.*note \([0-9]\+\).*/\1/p' | head -n 1)"
      vel="$(echo "$line"  | sed -n 's/.*velocity \([0-9]\+\).*/\1/p' | head -n 1)"
      [[ -n "${note:-}" && -n "${vel:-}" ]] || continue

      # only treat velocity > 0 as press
      if [[ "$note" -eq "$TRIGGER_NOTE" && "$vel" -gt 0 ]]; then
        now="$(date +%s)"
        if (( now - last >= MIN_GAP_SEC )); then
          last="$now"
          log "TRIGGER: note=$note vel=$vel -> running debug dump"
          "$HOME/bin/roaring_audio_debug_dump.sh" >/dev/null 2>&1 || true
          log "dump complete (check Desktop)"
        fi
      fi
    fi
  done
}

main
