#!/usr/bin/env bash
set -euo pipefail

# 10/1/2026-2
# Summary:
# - Creates a timestamped debug bundle (tar.gz) on your Desktop.
# - Produces labeled, readable text dumps + a single all_errors.txt.
# - Safe to run anytime.

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="$HOME/Desktop/roaring_debug_$TS"
TAR="$HOME/Desktop/roaring_debug_$TS.tar.gz"
CONF="$HOME/.config/roaring_mixer.conf"

mkdir -p "$OUTDIR"

log() { echo "[debug-dump] $(date +%H:%M:%S) $*"; }

# Best-effort: avoid low per-shell FD limits when querying PipeWire.
ulimit -n 1048576 2>/dev/null || true

ROARING_UNITS=(
  roaring-vm-sinks.service
  roaring-mic-busses.service
  roaring-mic-routesd.service
  roaring-audio-routesd.service
  roaring-audio-stackd.service
  lpd8-mixer.service
  roaring-audio-autorefresh.path
  roaring-audio-autorefresh.service
  roaring-carla-session.service
)

PIPEWIRE_UNITS=(
  pipewire.service
  pipewire-pulse.service
  wireplumber.service
)

KEY_UNITS=( "${PIPEWIRE_UNITS[@]}" "${ROARING_UNITS[@]}" )

write_cmd() {
  local name="$1"; shift
  {
    echo "### CMD: $*"
    echo "### WHEN: $(date --iso-8601=seconds)"
    echo
    "$@" || true
  } > "$OUTDIR/$name"
}

write_raw_cmd() {
  local name="$1"; shift
  "$@" > "$OUTDIR/$name" 2>/dev/null || true
}

write_file_if_exists() {
  local path="$1"
  if [[ -f "$path" ]]; then
    mkdir -p "$OUTDIR/files$(dirname "$path")"
    cp -a "$path" "$OUTDIR/files$path" || true
  fi
}

log "writing summary..."
{
  echo "### roaring audio debug summary"
  echo "timestamp=$TS"
  echo "date=$(date --iso-8601=seconds)"
  echo "host=$(hostname)"
  echo "user=$USER"
  echo "kernel=$(uname -r)"
  echo "uptime=$(uptime -p 2>/dev/null || true)"
  echo
  echo "### config (roaring_mixer.conf)"
  if [[ -f "$CONF" ]]; then
    sed 's/^/  /' "$CONF"
  else
    echo "  (missing)"
  fi
  echo
  echo "### unit state"
  for u in "${KEY_UNITS[@]}"; do
    status="$(systemctl --user is-active "$u" 2>/dev/null || true)"
    [[ -z "$status" ]] && status="unknown"
    printf '%-40s %s\n' "$u" "$status"
  done
  echo
  echo "### limits"
  echo "ulimit_nofile=$(ulimit -n 2>/dev/null || true)"
  systemctl --user show pipewire-pulse.service -p LimitNOFILE 2>/dev/null || true
  echo
  echo "### unit files (carla)"
  systemctl --user list-unit-files 2>/dev/null | grep -i carla || true
  echo
  echo "### carla quick check"
  systemctl --user --no-pager --full status roaring-carla-session.service 2>&1 || true
  echo
  pgrep -fa carla 2>&1 || true
  echo
  echo "### failed units"
  systemctl --user --no-pager --failed 2>&1 || true
} > "$OUTDIR/00_summary.txt"

log "writing index..."
cat > "$OUTDIR/index.txt" <<'EOF'
00_summary.txt          - host/config snapshot + unit state overview
01_systemd_status.txt   - full systemctl status + filtered list-units
02_systemd_show.txt     - key fields (restarts/status/result) per unit
03_pactl_summary.txt    - pactl info + short sinks/sources/modules
04_pactl_full.txt       - full sinks + sources
05_wpctl.txt            - wpctl status + default sink/source inspect (if available)
06_pw_dump.json         - raw pw-dump JSON (if available)
07_journal_roaring.txt  - recent roaring + carla journal
08_journal_pipewire.txt - recent pipewire/wireplumber journal
all_errors.txt          - all user-level errors (journalctl -p err..alert)
10_files_and_hashes.txt - bin listing + hashes of key scripts/config
files/                  - copies of referenced scripts/configs
EOF

log "collecting systemd status..."
write_cmd "01_systemd_status.txt" bash -lc '
  echo "## systemctl --user status (key units)"
  systemctl --user --no-pager --full status \
    pipewire.service pipewire-pulse.service wireplumber.service \
    roaring-vm-sinks.service roaring-mic-busses.service roaring-mic-routesd.service \
    roaring-audio-routesd.service roaring-audio-stackd.service lpd8-mixer.service \
    roaring-audio-autorefresh.path roaring-audio-autorefresh.service \
    roaring-carla-session.service 2>&1 || true
  echo
  echo "## systemctl --user list-units (filtered)"
  systemctl --user --no-pager list-units --type=service 2>&1 | grep -E -i "roaring|pipewire|wireplumber|carla|lpd8" || true
'

log "collecting systemd show..."
write_cmd "02_systemd_show.txt" bash -lc '
  for u in \
    pipewire.service pipewire-pulse.service wireplumber.service \
    roaring-vm-sinks.service roaring-mic-busses.service roaring-mic-routesd.service \
    roaring-audio-routesd.service roaring-audio-stackd.service lpd8-mixer.service \
    roaring-audio-autorefresh.path roaring-audio-autorefresh.service \
    roaring-carla-session.service; do
    echo "## $u"
    systemctl --user show "$u" \
      -p ActiveState -p SubState -p ActiveEnterTimestamp \
      -p NRestarts -p ExecMainStatus -p Result -p MainPID 2>&1 || true
    echo
  done
'

log "collecting pactl..."
write_cmd "03_pactl_summary.txt" bash -lc '
  echo "## pactl info"
  pactl info 2>&1 || true
  echo
  echo "## pactl list short sinks"
  pactl list short sinks 2>&1 || true
  echo
  echo "## pactl list short sources"
  pactl list short sources 2>&1 || true
  echo
  echo "## pactl list short modules"
  pactl list short modules 2>&1 || true
'

write_cmd "04_pactl_full.txt" bash -lc '
  echo "## pactl list sinks"
  pactl list sinks 2>&1 || true
  echo
  echo "## pactl list sources"
  pactl list sources 2>&1 || true
'

if command -v wpctl >/dev/null 2>&1; then
  log "collecting wpctl..."
  write_cmd "05_wpctl.txt" bash -lc '
    echo "## wpctl status"
    wpctl status 2>&1 || true
    echo
    echo "## wpctl inspect default sink"
    id="$(wpctl status 2>/dev/null | awk "/Default Sink:/ {print $NF}" | tr -d ".")"
    [[ -n "${id:-}" ]] && wpctl inspect "$id" 2>&1 || true
    echo
    echo "## wpctl inspect default source"
    sid="$(wpctl status 2>/dev/null | awk "/Default Source:/ {print $NF}" | tr -d ".")"
    [[ -n "${sid:-}" ]] && wpctl inspect "$sid" 2>&1 || true
  '
fi

if command -v pw-dump >/dev/null 2>&1; then
  log "collecting pw-dump..."
  write_raw_cmd "06_pw_dump.json" pw-dump
fi

log "collecting journals (last 30 minutes)..."
write_cmd "07_journal_roaring.txt" journalctl --user --since "30 min ago" --no-pager \
  -u roaring-vm-sinks.service -u roaring-mic-busses.service -u roaring-mic-routesd.service \
  -u roaring-audio-routesd.service -u roaring-audio-stackd.service -u lpd8-mixer.service \
  -u roaring-audio-autorefresh.path -u roaring-audio-autorefresh.service \
  -u roaring-carla-session.service

write_cmd "08_journal_pipewire.txt" journalctl --user --since "30 min ago" --no-pager \
  -u pipewire.service -u pipewire-pulse.service -u wireplumber.service

log "collecting all errors..."
write_cmd "all_errors.txt" bash -lc '
  echo "## systemctl --user --failed"
  systemctl --user --no-pager --failed 2>&1 || true
  echo
  echo "## journalctl --user -p err..alert (last 2 hours)"
  journalctl --user -p err..alert --since "2 hours ago" --no-pager 2>&1 || true
'

log "collecting script hashes + configs..."
write_cmd "10_files_and_hashes.txt" bash -lc '
  set -e
  echo "## bin listing"
  ls -la "$HOME/bin" || true
  echo
  echo "## hashes (selected)"
  for f in \
    "$HOME/bin/roaring_audio_routesd.sh" \
    "$HOME/bin/roaring_vm_sinks.sh" \
    "$HOME/bin/roaring_mic_bussesd.sh" \
    "$HOME/bin/roaring_mic_routesd.sh" \
    "$HOME/bin/lpd8_mixer.sh" \
    "$HOME/bin/roaring_restart_everything.sh" \
    "$HOME/bin/roaring_audio_debug_dump.sh" \
    "$HOME/.config/roaring_mixer.conf" \
  ; do
    [[ -f "$f" ]] || continue
    sha256sum "$f" || true
  done
'

# Copy key files (so the bundle is self-contained)
write_file_if_exists "$HOME/bin/roaring_audio_routesd.sh"
write_file_if_exists "$HOME/bin/roaring_vm_sinks.sh"
write_file_if_exists "$HOME/bin/roaring_mic_bussesd.sh"
write_file_if_exists "$HOME/bin/roaring_mic_routesd.sh"
write_file_if_exists "$HOME/bin/lpd8_mixer.sh"
write_file_if_exists "$HOME/bin/roaring_restart_everything.sh"
write_file_if_exists "$HOME/bin/roaring_audio_debug_dump.sh"
write_file_if_exists "$HOME/.config/roaring_mixer.conf"
write_file_if_exists "$HOME/.config/systemd/user/roaring-carla-session.service"
write_file_if_exists "$HOME/.config/systemd/user/roaring-audio-autorefresh.path"
write_file_if_exists "$HOME/.config/systemd/user/roaring-audio-autorefresh.service"
write_file_if_exists "$HOME/.config/systemd/user/roaring-audio-routesd.service"
write_file_if_exists "$HOME/.config/systemd/user/roaring-audio-stackd.service"
write_file_if_exists "$HOME/.config/systemd/user/roaring-mic-busses.service"
write_file_if_exists "$HOME/.config/systemd/user/roaring-mic-routesd.service"
write_file_if_exists "$HOME/.config/systemd/user/roaring-vm-sinks.service"
write_file_if_exists "$HOME/.config/systemd/user/lpd8-mixer.service"

log "packing $TAR ..."
tar -czf "$TAR" -C "$(dirname "$OUTDIR")" "$(basename "$OUTDIR")"

log "done -> $TAR"
echo "$TAR"
