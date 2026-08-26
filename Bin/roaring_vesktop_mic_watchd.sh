#!/usr/bin/env bash
set -euo pipefail

# roaring_vesktop_mic_watchd.sh
# 5/12/2026-1  self-restart on pactl subscribe exit (mirrors vesktop-stream-watchd)
# Watches pactl events; whenever a Vesktop source-output appears muted or at
# zero volume, immediately unmutes it and restores 100%.

LOG="$HOME/.cache/roaring-vesktop-mic-watchd.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

log() { echo "[vesktop-mic-watch] $(date +%H:%M:%S) $*"; }

wait_for_pactl() {
    until pactl info >/dev/null 2>&1; do sleep 0.5; done
}

fix_vesktop_outputs() {
    # Find all source-output IDs belonging to Vesktop that are muted or silent
    pactl list source-outputs 2>/dev/null | python3 -c "
import sys, re
text = sys.stdin.read()
for block in re.split(r'(?=Source Output #)', text):
    if 'dev.vencord.Vesktop' not in block:
        continue
    m = re.search(r'Source Output #(\d+)', block)
    if not m:
        continue
    so_id = m.group(1)
    muted  = bool(re.search(r'Mute:\s+yes', block))
    vol_m  = re.search(r'Volume:.*?(\d+)\s*/', block)
    vol    = int(vol_m.group(1)) if vol_m else 65536
    if muted or vol < 65536:
        print(so_id)
" | while read -r id; do
        log "fixing Vesktop source-output #$id"
        pactl set-source-output-mute   "$id" 0     || true
        pactl set-source-output-volume "$id" 65536 || true
    done
}

main() {
    log "starting"
    wait_for_pactl
    fix_vesktop_outputs   # catch anything already muted at startup

    pactl subscribe 2>/dev/null | while IFS= read -r event; do
        [[ "$event" == *"on source-output"* ]] || continue
        sleep 0.4         # let WirePlumber stream-restore apply first, then override
        fix_vesktop_outputs
    done

    log "pactl subscribe exited — restarting in 3s"
    sleep 3
    exec "$0"
}

main
