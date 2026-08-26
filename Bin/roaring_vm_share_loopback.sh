#!/usr/bin/env bash
# roaring_vm_share_loopback.sh — ensures VM-SHARE mirrors vm_game + vm_music
# (NEVER vm_chat) so screen-share tools have a safe target that can't
# include your own received call audio.
#
# Uses DIRECT pw-link port connections, not module-loopback. PipeWire
# natively mixes multiple sources feeding the same destination ports, so
# this sounds identical to the old loopback-module approach -- but a
# direct pw-link creates ZERO new enumerable PipeWire nodes, whereas each
# module-loopback creates 2 bridge nodes that Vesktop's screenshare "Audio
# Sources" picker (in Granular Selection mode) then shows as ~3 near-
# duplicate rows each. See roaring-machine SKILL.md section 11.5 for the
# full story on why this matters.
#
# Idempotent: safe to run repeatedly, pw-link silently no-ops on an
# already-existing link.
set -uo pipefail
LOG="$HOME/.cache/roaring-vm-share.log"
log() { echo "[vm-share] $(date +%H:%M:%S) $*" >> "$LOG"; }

# clean up any old module-loopback-based version of this bus, if present
# (loops over every match, doesn't assume a single match)
for src in "vm_game.monitor" "vm_music.monitor"; do
  while IFS= read -r id; do
    [ -n "$id" ] && pactl unload-module "$id" >/dev/null 2>&1 && log "removed old loopback module $id ($src -> vm_share)"
  done < <(pactl list short modules 2>/dev/null | awk -v s="source=$src " '$2=="module-loopback" && index($0,s) && index($0,"sink=vm_share") {print $1}')
done

# ensure vm_share sink itself exists
if ! pactl list sinks short 2>/dev/null | grep -q "^\S*\s*vm_share\s"; then
  pactl load-module module-null-sink sink_name=vm_share sink_properties=device.description=VM-SHARE >/dev/null 2>&1
  log "created vm_share sink"
  sleep 0.5
fi

# direct port links -- no bridge nodes created
pw-link vm_game:monitor_FL  vm_share:playback_FL >/dev/null 2>&1
pw-link vm_game:monitor_FR  vm_share:playback_FR >/dev/null 2>&1
pw-link vm_music:monitor_FL vm_share:playback_FL >/dev/null 2>&1
pw-link vm_music:monitor_FR vm_share:playback_FR >/dev/null 2>&1

log "reconciled (direct pw-link mode)"
