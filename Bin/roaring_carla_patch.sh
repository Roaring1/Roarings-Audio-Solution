#!/usr/bin/env bash
# roaring_carla_patch.sh
# Connects sm7b_mono -> Carla audio inputs after Carla starts.
# Carla's .carxp patchbay restore references SM7B:input_FL / SM7B:monitor_FL
# which don't exist as PipeWire ports on the sm7b_mono remap-source node
# (it only has capture_MONO). This script creates the correct links manually.
set -euo pipefail

log() { echo "[carla-patch] $(date +'%H:%M:%S') $*"; }

wait_for_node() {
  local name="$1" max=30 i=0
  until pw-cli ls Node 2>/dev/null | grep -q "node.name = \"${name}\""; do
    ((i++)) || true
    if (( i > max )); then
      log "timeout waiting for node: ${name}"
      exit 1
    fi
    sleep 0.5
  done
  log "node ready: ${name}"
}

wait_for_port() {
  local node="$1" port="$2" max=20 i=0
  until pw-link -l 2>/dev/null | grep -q "^  ${port}$" || \
        pw-dump 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
nodes={o['id']:o for o in d if o.get('type')=='PipeWire:Interface:Node'}
ports=[o for o in d if o.get('type')=='PipeWire:Interface:Port']
target_nid=next((nid for nid,n in nodes.items() if n.get('info',{}).get('props',{}).get('node.name')=='${node}'),None)
if not target_nid: sys.exit(1)
found=any(p.get('info',{}).get('props',{}).get('node.id')==target_nid and p.get('info',{}).get('props',{}).get('port.name')=='${port}' for p in ports)
sys.exit(0 if found else 1)
" 2>/dev/null; do
    ((i++)) || true
    if (( i > max )); then
      log "timeout waiting for ${node}:${port}"
      return 1
    fi
    sleep 0.5
  done
}

log "waiting for sm7b_mono and Carla..."
wait_for_node "sm7b_mono"
wait_for_node "Carla"

# Give Carla a moment to fully initialize its ports
sleep 1

log "linking sm7b_mono -> Carla inputs"
pw-link sm7b_mono:capture_MONO Carla:audio-in1 2>/dev/null && log "linked audio-in1" || log "audio-in1 already linked or failed"
pw-link sm7b_mono:capture_MONO Carla:audio-in2 2>/dev/null && log "linked audio-in2" || log "audio-in2 already linked or failed"

log "done"
