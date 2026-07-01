#!/usr/bin/env bash
# Watch for Sober capture streams and route them to b1_mic via PipeWire metadata.
# Runs as a persistent service; polls every 2 seconds.

set -euo pipefail

log() { echo "[sober-mic-watch] $(date +'%H:%M:%S') $*"; }

get_b1_serial() {
    pw-dump 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for obj in data:
    p = obj.get('info', {}).get('props', {})
    if obj.get('type') == 'PipeWire:Interface:Node' and p.get('node.name') == 'b1_mic':
        print(p.get('object.serial', ''))
        break
" 2>/dev/null || true
}

get_sober_capture_id() {
    pw-dump 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for obj in data:
    p = obj.get('info', {}).get('props', {})
    if (obj.get('type') == 'PipeWire:Interface:Node'
            and p.get('node.name') == 'Sober'
            and 'Input' in p.get('media.class', '')):
        print(obj['id'])
        break
" 2>/dev/null || true
}

get_metadata_target() {
    local node_id="$1"
    # Output format: update: id:N key:'target.object' value:'VAL' type:'...'
    # Split on ' gives: $1=prefix $2=target.object $3= value: $4=VAL
    pw-metadata -n default 2>/dev/null \
        | awk -F"'" "/id:${node_id} key:'target.object'/ {print \$4}" \
        || true
}

log "started"

last_sober_id=""

while true; do
    sleep 2

    b1_serial="$(get_b1_serial)"
    [[ -z "$b1_serial" ]] && continue

    sober_id="$(get_sober_capture_id)"
    [[ -z "$sober_id" ]] && { last_sober_id=""; continue; }

    # Check current metadata target for this Sober node
    current="$(get_metadata_target "$sober_id")"

    if [[ "$current" != "$b1_serial" ]]; then
        log "routing Sober (node $sober_id) -> b1_mic (serial $b1_serial)"
        pw-metadata -n default "$sober_id" target.object "$b1_serial" \
            >/dev/null 2>&1 && log "done" || log "pw-metadata failed"
        last_sober_id="$sober_id"
    fi
done
