#!/usr/bin/env bash
set -euo pipefail

# Summary:
# - Waits for the LPD8 ALSA sequencer port to appear
# - Listens for pad presses + knob CC events
# - On pad press, writes a full debug dump to ~/.cache and logs where it went

LOG="$HOME/.cache/roaring-lpd8-debug-listener.log"
mkdir -p "$HOME/.cache"
exec >>"$LOG" 2>&1

log() { echo "[lpd8-debug] $(date +%H:%M:%S) $*"; }

find_lpd8_port() {
  # aseqdump -l line looks like: " 40:0    LPD8    LPD8 MIDI 1"
  aseqdump -l 2>/dev/null | awk '
    $2 ~ /^[0-9]+:[0-9]+$/ && $3=="LPD8" { print $2; exit }
  '
}

dump_audio_state() {
  local out="$HOME/.cache/roaring_dump_$(date +%Y-%m-%d_%H-%M-%S).txt"

  {
    echo "### roaring audio dump @ $(date -Is)"
    echo "host: $(hostname)"
    echo "uname: $(uname -a)"
    echo

    echo "## systemd --user status (key units)"
    systemctl --user --no-pager status \
      pipewire.service pipewire-pulse.service wireplumber.service \
      roaring-vm-sinks.service roaring-mic-busses.service roaring-mic-routesd.service \
      roaring-audio-routesd.service roaring-audio-stackd.service \
      lpd8-mixer.service roaring-lpd8-debug-listener.service \
      2>&1 || true
    echo

    echo "## systemd --user list-units (roaring/pipewire/wireplumber)"
    systemctl --user --no-pager list-units --type=service 2>&1 | egrep -i 'roaring|pipewire|wireplumber|carla|lpd8' || true
    echo

    echo "## pactl info"
    pactl info 2>&1 || true
    echo

    echo "## pactl list short sinks/sources/modules"
    pactl list short sinks 2>&1 || true
    echo
    pactl list short sources 2>&1 || true
    echo
    pactl list short modules 2>&1 || true
    echo

    echo "## wpctl status"
    wpctl status 2>&1 || true
    echo

    echo "## pw-cli (nodes + links) [best-effort]"
    pw-cli ls Node 2>&1 || true
    echo
    pw-cli ls Link 2>&1 || true
    echo

    echo "## recent journals (roaring services)"
    for u in roaring-audio-routesd.service roaring-audio-stackd.service roaring-mic-routesd.service lpd8-mixer.service; do
      echo "--- journal: $u (last 200 lines)"
      journalctl --user -u "$u" --no-pager -n 200 2>&1 || true
      echo
    done
  } >"$out"

  log "dump written: $out"
}

main() {
  log "starting"

  local port=""
  while [[ -z "${port:-}" ]]; do
    port="$(find_lpd8_port || true)"
    if [[ -z "${port:-}" ]]; then
      log "LPD8 port not found yet (aseqdump -l). waiting..."
      sleep 2
    fi
  done

  log "LPD8 port found: $port"
  log "listening: aseqdump -p $port"

  # Notes:
  # - You can pick which pad triggers a dump by matching "note=" below.
  # - This prints ALL knob CC traffic too (good for diagnosing jitter/lag).
  aseqdump -p "$port" 2>/dev/null | while IFS= read -r line; do
    # Example patterns include:
    # "Note on                0, note 36, velocity 127"
    # "Control change         0, controller 1, value 96"

    if echo "$line" | grep -q "Control change"; then
      log "CC: $line"
    fi

    if echo "$line" | grep -q "Note on"; then
      log "PAD: $line"
      # Trigger on any pad press (or restrict to a single note if you want)
      dump_audio_state
    fi
  done
}

main
