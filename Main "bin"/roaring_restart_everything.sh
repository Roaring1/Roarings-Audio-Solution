#!/usr/bin/env bash
set -euo pipefail

# 10/1/2026-2
# Summary:
# - One-button reset for the whole Roaring audio stack.
# - Stops Roaring services (+ optional autorefresh), clears systemd failures.
# - Hard mode: restarts WirePlumber/PipeWire/PipeWire-Pulse, then best-effort module purge.
# - Starts Roaring services in a safe order and prints quick status.

MODE="hard"
DISABLE_AUTOREFRESH="yes"

for a in "${@:-}"; do
  case "$a" in
    --soft) MODE="soft" ;;
    --hard) MODE="hard" ;;
    --no-disable-autorefresh) DISABLE_AUTOREFRESH="no" ;;
    *) ;;
  esac
done

ROARING_UNITS=(
  "roaring-audio-autorefresh.path"
  "roaring-audio-autorefresh.service"
  "lpd8-mixer.service"
  "roaring-audio-routesd.service"
  "roaring-mic-routesd.service"
  "roaring-vm-sinks.service"
  "roaring-mic-busses.service"
)

PIPEWIRE_UNITS=(
  "wireplumber.service"
  "pipewire.service"
  "pipewire-pulse.service"
)

log() { echo "[restart-everything] $(date +'%H:%M:%S') $*"; }

wait_for_pactl() {
  local i=0
  until pactl info >/dev/null 2>&1; do
    ((i++)) || true
    if (( i > 200 )); then
      log "pactl not responding after ~40s; continuing anyway."
      return 0
    fi
    sleep 0.2
  done
}

stop_everything() {
  log "Stopping Roaring services + autorefresh..."
  systemctl --user stop "${ROARING_UNITS[@]}" >/dev/null 2>&1 || true
}

disable_autorefresh_if_requested() {
  if [[ "$DISABLE_AUTOREFRESH" == "yes" ]]; then
    log "Disabling roaring-audio-autorefresh.path to prevent re-trigger while debugging..."
    systemctl --user disable --now roaring-audio-autorefresh.path >/dev/null 2>&1 || true
  fi
}

restart_pipewire_stack() {
  log "Restarting PipeWire stack..."
  systemctl --user restart "${PIPEWIRE_UNITS[@]}" >/dev/null 2>&1 || true
}

pipewire_pulse_allows_unload() {
  # Do a single harmless probe. If the server returns "Operation not permitted" for unload,
  # there's no point spamming unload attempts (and it spams pipewire-pulse logs too).
  local out
  out="$(pactl unload-module 999999 2>&1 || true)"
  if echo "$out" | grep -qi "Operation not permitted"; then
    return 1
  fi
  return 0
}

purge_our_pulse_modules_best_effort() {
  command -v pactl >/dev/null 2>&1 || { log "pactl missing; skipping module purge"; return 0; }
  wait_for_pactl

  if ! pipewire_pulse_allows_unload; then
    log "PipeWire-Pulse is denying UNLOAD_MODULE; skipping module purge to avoid log spam."
    return 0
  fi

  log "Purging Roaring Pulse modules (best-effort)..."

  # unload loopbacks related to vm_* and mic_b*
  while read -r mid mname margs; do
    [[ -z "${mid:-}" ]] && continue

    if [[ "$mname" == "module-loopback" ]]; then
      if [[ "$margs" == *"source=vm_game.monitor"* || "$margs" == *"source=vm_chat.monitor"* || "$margs" == *"source=vm_music.monitor"* ]]; then
        pactl unload-module "$mid" >/dev/null 2>&1 || true
      fi
      if [[ "$margs" == *"sink=mic_b1"* || "$margs" == *"sink=mic_b2"* || "$margs" == *"source=mic_b1.monitor"* || "$margs" == *"source=mic_b2.monitor"* ]]; then
        pactl unload-module "$mid" >/dev/null 2>&1 || true
      fi
    fi
  done < <(pactl list short modules 2>/dev/null || true)

  # unload null sinks for vm_* + mic_b*
  while read -r mid mname margs; do
    [[ -z "${mid:-}" ]] && continue
    if [[ "$mname" == "module-null-sink" ]]; then
      if [[ "$margs" == *"sink_name=vm_game"* || "$margs" == *"sink_name=vm_chat"* || "$margs" == *"sink_name=vm_music"* || \
            "$margs" == *"sink_name=mic_b1"* || "$margs" == *"sink_name=mic_b2"* ]]; then
        pactl unload-module "$mid" >/dev/null 2>&1 || true
      fi
    fi
  done < <(pactl list short modules 2>/dev/null || true)
}

start_roaring_stack() {
  log "Starting Roaring services..."
  systemctl --user start \
    "roaring-vm-sinks.service" \
    "roaring-mic-busses.service" \
    "roaring-mic-routesd.service" \
    "roaring-audio-routesd.service" \
    "lpd8-mixer.service" >/dev/null 2>&1 || true
}

main() {
  log "MODE=$MODE DISABLE_AUTOREFRESH=$DISABLE_AUTOREFRESH"

  log "daemon-reload + reset-failed..."
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed >/dev/null 2>&1 || true

  stop_everything
  disable_autorefresh_if_requested

  if [[ "$MODE" == "hard" ]]; then
    restart_pipewire_stack
    purge_our_pulse_modules_best_effort
  fi

  start_roaring_stack

  log "Done. Quick status:"
  systemctl --user --no-pager --full status \
    roaring-vm-sinks.service \
    roaring-mic-busses.service \
    roaring-mic-routesd.service \
    roaring-audio-routesd.service \
    lpd8-mixer.service || true
}

main
