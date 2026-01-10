#!/usr/bin/env bash
set -euo pipefail

# 10/1/2026-1
# Summary:
# - Creates a timestamped debug bundle (tar.gz) on your Desktop.
# - Includes: pactl state, wpctl status, pipewire/wireplumber service info,
#   recent journals for your units, and hashes of key scripts/config.
# - Safe to run anytime.

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="$HOME/Desktop/roaring_debug_$TS"
TAR="$HOME/Desktop/roaring_debug_$TS.tar.gz"

mkdir -p "$OUTDIR"

log() { echo "[debug-dump] $(date +%H:%M:%S) $*"; }

write_cmd() {
  local name="$1"; shift
  {
    echo "### CMD: $*"
    echo "### WHEN: $(date --iso-8601=seconds)"
    echo
    "$@" || true
  } > "$OUTDIR/$name"
}

write_file_if_exists() {
  local path="$1"
  if [[ -f "$path" ]]; then
    mkdir -p "$OUTDIR/files$(dirname "$path")"
    cp -a "$path" "$OUTDIR/files$path" || true
  fi
}

log "collecting systemd status..."
write_cmd "systemd_status.txt" systemctl --user status \
  roaring-vm-sinks.service roaring-mic-busses.service roaring-mic-routesd.service \
  roaring-audio-routesd.service lpd8-mixer.service roaring-audio-autorefresh.path \
  roaring-audio-autorefresh.service pipewire.service pipewire-pulse.service wireplumber.service \
  --no-pager

write_cmd "systemd_show_pipewire.txt" bash -lc '
  systemctl --user show pipewire-pulse.service -p ActiveState -p ActiveEnterTimestamp -p NRestarts -p ExecMainStatus -p Result 2>/dev/null || true
  systemctl --user show wireplumber.service   -p ActiveState -p ActiveEnterTimestamp -p NRestarts -p ExecMainStatus -p Result 2>/dev/null || true
  systemctl --user show pipewire.service      -p ActiveState -p ActiveEnterTimestamp -p NRestarts -p ExecMainStatus -p Result 2>/dev/null || true
'

log "collecting pactl + wpctl..."
write_cmd "pactl_info.txt" pactl info
write_cmd "pactl_sinks_short.txt" pactl list short sinks
write_cmd "pactl_sources_short.txt" pactl list short sources
write_cmd "pactl_modules_short.txt" pactl list short modules
write_cmd "pactl_sinks_full.txt" pactl list sinks
write_cmd "pactl_sources_full.txt" pactl list sources

if command -v wpctl >/dev/null 2>&1; then
  write_cmd "wpctl_status.txt" wpctl status
  write_cmd "wpctl_inspect_default_sink.txt" bash -lc '
    id="$(wpctl status 2>/dev/null | awk "/Default Sink:/ {print \$NF}" | tr -d "." )"
    [[ -n "${id:-}" ]] && wpctl inspect "$id" || true
  '
fi

if command -v pw-dump >/dev/null 2>&1; then
  write_cmd "pw_dump.json" pw-dump
fi

log "collecting journals (last 20 minutes)..."
write_cmd "journal_roaring_units.txt" journalctl --user --since "20 min ago" --no-pager \
  -u roaring-vm-sinks.service -u roaring-mic-busses.service -u roaring-mic-routesd.service \
  -u roaring-audio-routesd.service -u lpd8-mixer.service -u roaring-audio-autorefresh.path \
  -u roaring-audio-autorefresh.service

write_cmd "journal_pipewire_stack.txt" journalctl --user --since "20 min ago" --no-pager \
  -u pipewire.service -u pipewire-pulse.service -u wireplumber.service

log "collecting script hashes + configs..."
write_cmd "hashes_and_ls.txt" bash -lc '
  set -e
  echo "### bin listing"
  ls -la "$HOME/bin" || true
  echo
  echo "### hashes (selected)"
  for f in \
    "$HOME/bin/roaring_audio_routesd.sh" \
    "$HOME/bin/roaring_vm_sinks.sh" \
    "$HOME/bin/roaring_mic_bussesd.sh" \
    "$HOME/bin/roaring_mic_routesd.sh" \
    "$HOME/bin/lpd8_mixer.sh" \
    "$HOME/bin/roaring_restart_everything.sh" \
    "$HOME/.config/roaring_mixer.conf" \
  ; do
    [[ -f "$f" ]] || continue
    sha256sum "$f" || true
  done
'

# Copy key files (so the bundle is self-contained)
write_file_if_exists "$HOME/bin/roaring_audio_routesd.sh"
write_file_if_exists "$HOME/bin/lpd8_mixer.sh"
write_file_if_exists "$HOME/bin/roaring_restart_everything.sh"
write_file_if_exists "$HOME/.config/roaring_mixer.conf"

log "writing meta..."
{
  echo "timestamp=$TS"
  echo "host=$(hostname)"
  echo "user=$USER"
  echo "kernel=$(uname -r)"
  echo "date=$(date --iso-8601=seconds)"
} > "$OUTDIR/meta.txt"

log "packing $TAR ..."
tar -czf "$TAR" -C "$(dirname "$OUTDIR")" "$(basename "$OUTDIR")"

log "done -> $TAR"
echo "$TAR"
