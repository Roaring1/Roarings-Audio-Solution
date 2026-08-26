#!/usr/bin/env bash
# Watch for Sober capture streams and route them to b1_mic via PipeWire metadata.
# Runs as a persistent service.
#
# Gap #7: the original loop ran `sleep 2` at the TOP of every iteration, so
# there was always up to a 2s window in which Sober recorded to the wrong
# source (b2_mic) before routing kicked in. Now:
#   * the first check runs IMMEDIATELY (0s latency when Sober is already up),
#   * the poll interval is configurable via SOBER_WATCH_POLL (default 0.5s),
# cutting worst-case latency from 2s to 0.5s without the fragility of a
# long-lived `pw-metadata --monitor` subprocess that would be far harder to
# supervise and restart cleanly under systemd.

set -euo pipefail

POLL="${SOBER_WATCH_POLL:-0.5}"

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

route_once() {
    local b1_serial sober_id current
    b1_serial="$(get_b1_serial)"
    if [[ -z "$b1_serial" ]]; then return 0; fi

    sober_id="$(get_sober_capture_id)"
    if [[ -z "$sober_id" ]]; then return 0; fi

    current="$(get_metadata_target "$sober_id")"
    if [[ "$current" == "$b1_serial" ]]; then return 0; fi

    log "routing Sober (node $sober_id) -> b1_mic (serial $b1_serial)"
    # if/then/else, not A && B || C: `log done` could itself fail under
    # `set -e` and wrongly trigger the failure branch (SC2015).
    if pw-metadata -n default "$sober_id" target.object "$b1_serial" \
            >/dev/null 2>&1; then
        log "done"
    else
        log "pw-metadata failed"
    fi
}

main() {
    log "started (poll ${POLL}s)"
    local first=1
    while true; do
        # Check immediately on the first pass (no startup latency); sleep only
        # between subsequent passes.
        if [[ "$first" == "1" ]]; then first=0; else sleep "$POLL"; fi
        route_once
    done
}

# Only auto-run when executed directly; allows sourcing functions in tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
