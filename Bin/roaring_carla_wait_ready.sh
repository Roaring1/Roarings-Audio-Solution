#!/usr/bin/env bash
set -euo pipefail

# Wait for the user's audio session, Wayland compositor and named virtual
# sinks before Carla loads its saved project and restores its patchbay.
wait_for_pactl() {
  local attempt
  for attempt in $(seq 1 120); do
    if pactl info >/dev/null 2>&1; then
      echo "carla-pre: PipeWire/Pulse ready"
      return 0
    fi
    sleep 0.5
  done
  echo "carla-pre: PipeWire/Pulse did not become ready within 60 seconds" >&2
  return 1
}

wait_for_wayland() {
  local runtime_dir wayland_display sock attempt
  runtime_dir="$(printenv XDG_RUNTIME_DIR 2>/dev/null || true)"
  [[ -n "$runtime_dir" ]] || runtime_dir="/run/user/1000"
  wayland_display="$(printenv WAYLAND_DISPLAY 2>/dev/null || true)"
  [[ -n "$wayland_display" ]] || wayland_display="wayland-0"
  sock="$runtime_dir/$wayland_display"

  for attempt in $(seq 1 120); do
    if [[ -S "$sock" ]]; then
      echo "carla-pre: Wayland socket ready ($sock)"
      return 0
    fi
    sleep 0.5
  done
  echo "carla-pre: Wayland socket did not become ready within 60 seconds ($sock)" >&2
  return 1
}

wait_for_virtual_sinks() {
  local attempt have missing name
  for attempt in $(seq 1 120); do
    have="$(pactl list short sinks 2>/dev/null | awk '{print $2}' || true)"
    missing=0
    for name in mic_b1 mic_b2 vm_game vm_chat vm_music; do
      if ! grep -qx "$name" <<< "$have"; then
        missing=1
        break
      fi
    done
    if (( missing == 0 )); then
      echo "carla-pre: virtual sinks ready (mic_b1 mic_b2 vm_game vm_chat vm_music)"
      return 0
    fi
    sleep 0.5
  done
  echo "carla-pre: required virtual sinks did not become ready within 60 seconds" >&2
  return 1
}

wait_for_pactl
wait_for_wayland
wait_for_virtual_sinks
