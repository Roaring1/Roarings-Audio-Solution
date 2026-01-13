#!/usr/bin/env bash
set -euo pipefail

# 10/1/2026-1
# Summary: Captures a single “state snapshot” (systemd + pipewire/pulse + pactl + journals)
#          into a timestamped tar.gz under ~/.cache/roaring-debug/.

OUTDIR="${HOME}/.cache/roaring-debug"
mkdir -p "$OUTDIR"

TS="$(date +%Y%m%d-%H%M%S)"
ROOT="${OUTDIR}/dump-${TS}"
mkdir -p "$ROOT"

log() { echo "[dump] $(date +%H:%M:%S) $*"; }

have() { command -v "$1" >/dev/null 2>&1; }

log "writing to: $ROOT"

{
  echo "### BASIC"
  date -Is
  uname -a
  echo
  echo "### UPTIME"
  uptime || true
} >"$ROOT/00_basic.txt"

{
  echo "### USER UNITS (status)"
  systemctl --user --no-pager status \
    pipewire.service pipewire-pulse.service wireplumber.service \
    roaring-vm-sinks.service roaring-mic-busses.service roaring-mic-routesd.service \
    roaring-audio-routesd.service roaring-audio-stackd.service lpd8-mixer.service \
    roaring-lpd8-debug-listener.service 2>&1 || true

  echo
  echo "### USER UNITS (show: restarts/status)"
  for u in pipewire.service pipewire-pulse.service wireplumber.service \
           roaring-vm-sinks.service roaring-mic-busses.service roaring-mic-routesd.service \
           roaring-audio-routesd.service roaring-audio-stackd.service lpd8-mixer.service; do
    echo "--- $u"
    systemctl --user show "$u" -p ActiveEnterTimestamp -p NRestarts -p ExecMainStatus -p Result 2>&1 || true
    echo
  done
} >"$ROOT/10_systemd.txt"

if have pactl; then
  {
    echo "### pactl info"
    pactl info 2>&1 || true
    echo
    echo "### sinks"
    pactl list short sinks 2>&1 || true
    echo
    echo "### sources"
    pactl list short sources 2>&1 || true
    echo
    echo "### modules"
    pactl list short modules 2>&1 || true
  } >"$ROOT/20_pactl.txt"
fi

if have wpctl; then
  wpctl status >"$ROOT/30_wpctl_status.txt" 2>&1 || true
fi

{
  echo "### journals (last 30min): pipewire / wireplumber / your services"
  journalctl --user --no-pager --since "30 min ago" \
    -u pipewire -u pipewire-pulse -u wireplumber \
    -u roaring-vm-sinks -u roaring-mic-busses -u roaring-mic-routesd \
    -u roaring-audio-routesd -u roaring-audio-stackd -u lpd8-mixer \
    -u roaring-lpd8-debug-listener 2>&1 || true
} >"$ROOT/40_journal.txt"

# Include current unit files + key scripts (so I can actually diff logic)
mkdir -p "$ROOT/config"
cp -a "${HOME}/.config/systemd/user" "$ROOT/config/systemd-user" 2>/dev/null || true
mkdir -p "$ROOT/bin"
cp -a "${HOME}/bin" "$ROOT/bin/bin" 2>/dev/null || true

TAR="${OUTDIR}/dump-${TS}.tar.gz"
tar -C "$OUTDIR" -czf "$TAR" "dump-${TS}"

log "DONE -> $TAR"
echo "$TAR"
