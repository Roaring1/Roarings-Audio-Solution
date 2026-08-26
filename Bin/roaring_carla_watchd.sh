#!/usr/bin/env bash
# roaring_carla_watchd.sh
# Gap #6: the carla-patch oneshot only runs once at boot, so when Carla is
# restarted (or a WirePlumber-only restart drops graph links) the
# sm7b->Carla and Carla->mic_b1/mic_b2 links vanish and never come back until
# the next reboot. This persistent watcher re-creates any MISSING Carla
# patchbay link, keeping BOTH b1_mic and b2_mic fed by Carla's processed
# output. It is fully idempotent: a link is only (re)created when absent, so
# there is no log spam and no duplicate links in steady state.
set -euo pipefail

# Match carla-patch: b2 is a second processed bus by default. Set B2_PROCESSED=0
# to stop healing the Carla->mic_b2 links (raw/unrouted b2).
B2_PROCESSED="${B2_PROCESSED:-1}"
POLL="${CARLA_WATCH_POLL:-3}"

log() { echo "[carla-watch] $(date +'%H:%M:%S') $*"; }

carla_present() {
  pw-cli ls Node 2>/dev/null | grep -q 'node.name = "Carla"'
}

# has_link OUTNODE OUTPORT INNODE INPORT
#   exit 0 -> the exact link exists
#   exit 1 -> pw-dump parsed cleanly and the link is CONFIRMED absent
#   exit 3 -> pw-dump was missing/empty/malformed (cannot decide)
# Resolves by node.name + port.name against pw-dump so it is immune to the
# node/port id churn that happens across restarts. The parser is defensive:
# a truncated, reordered, or wrong-shaped dump yields exit 3 (not a crash and
# not a false "absent"), so the caller can skip rather than spuriously relink.
has_link() {
  pw-dump 2>/dev/null | OUTN="$1" OUTP="$2" INN="$3" INP="$4" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
    if not isinstance(d, list):
        sys.exit(3)
    nid, pid = {}, {}
    for o in d:
        if not isinstance(o, dict):
            continue
        info = o.get("info")
        if not isinstance(info, dict):
            info = {}
        props = info.get("props")
        if not isinstance(props, dict):
            props = {}
        t = o.get("type")
        oid = o.get("id")
        if t == "PipeWire:Interface:Node":
            nid[oid] = props.get("node.name")
        elif t == "PipeWire:Interface:Port":
            pid[oid] = (props.get("node.id"), props.get("port.name"))
    outn, outp = os.environ["OUTN"], os.environ["OUTP"]
    inn, inp = os.environ["INN"], os.environ["INP"]
    for o in d:
        if not isinstance(o, dict) or o.get("type") != "PipeWire:Interface:Link":
            continue
        i = o.get("info")
        if not isinstance(i, dict):
            continue
        op = pid.get(i.get("output-port-id"), (None, None))
        ip = pid.get(i.get("input-port-id"), (None, None))
        if (nid.get(i.get("output-node-id")) == outn and op[1] == outp
                and nid.get(i.get("input-node-id")) == inn and ip[1] == inp):
            sys.exit(0)
    sys.exit(1)
except SystemExit:
    raise
except Exception:
    sys.exit(3)
' 2>/dev/null
}

ensure_link() {
  local outn="$1" outp="$2" inn="$3" inp="$4"
  local rc=0
  has_link "$outn" "$outp" "$inn" "$inp" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi
  if [[ "$rc" -eq 3 ]]; then
    log "pw-dump unavailable -- skipping ${outn}:${outp} -> ${inn}:${inp} this pass"
    return 0
  fi
  if pw-link "${outn}:${outp}" "${inn}:${inp}" 2>/dev/null; then
    log "re-linked ${outn}:${outp} -> ${inn}:${inp}"
  else
    log "failed to link ${outn}:${outp} -> ${inn}:${inp}"
  fi
}

ensure_carla_links() {
  ensure_link sm7b_mono capture_MONO Carla audio-in1
  ensure_link sm7b_mono capture_MONO Carla audio-in2
  ensure_link Carla audio-out1 mic_b1 playback_FL
  ensure_link Carla audio-out2 mic_b1 playback_FR
  if [[ "$B2_PROCESSED" == "1" ]]; then
    ensure_link Carla audio-out1 mic_b2 playback_FL
    ensure_link Carla audio-out2 mic_b2 playback_FR
  fi
}

main() {
  log "started (poll ${POLL}s, B2_PROCESSED=${B2_PROCESSED})"
  local was_present=0
  while true; do
    sleep "$POLL"
    if carla_present; then
      if [[ "$was_present" == "0" ]]; then
        log "Carla present -> ensuring patchbay links"
        was_present=1
      fi
      ensure_carla_links
    elif [[ "$was_present" == "1" ]]; then
      log "Carla went away -> will re-patch when it returns"
      was_present=0
    fi
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
