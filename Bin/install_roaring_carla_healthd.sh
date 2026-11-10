#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$HOME/bin"
UNIT_DIR="$HOME/.config/systemd/user"
CONFIG_DIR="$HOME/.config/roaring"

usage() {
  cat <<'EOF'
Install the intermittent Carla B1 audio sampler and repaired patch watcher.

Usage:
  install_roaring_carla_healthd.sh [--restart-watcher] [--enable-sampler]

Default behavior installs files and reloads user systemd only. The sampler
does not keep microphone taps open between checks. Use --enable-sampler to
enable an 8-second sample approximately every 10 minutes.
EOF
}

restart_watcher=0
enable_sampler=0
for arg in "$@"; do
  case "$arg" in
    --restart-watcher) restart_watcher=1 ;;
    --enable-sampler) enable_sampler=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if ! python3 -c 'import numpy' >/dev/null 2>&1; then
  echo "Python NumPy is required. On Nobara/Fedora: sudo dnf install python3-numpy" >&2
  exit 1
fi

install -d -m 0755 "$BIN_DIR" "$UNIT_DIR"
install -d -m 0700 "$CONFIG_DIR" "$HOME/.cache/roaring"
install -m 0755 "$ROOT/Bin/roaring_carla_healthd.py" "$BIN_DIR/roaring_carla_healthd.py"
install -m 0755 "$ROOT/Bin/roaring_carla_watchd.sh" "$BIN_DIR/roaring_carla_watchd.sh"
install -m 0644 "$ROOT/User/roaring-carla-healthd.service" "$UNIT_DIR/roaring-carla-healthd.service"
install -m 0644 "$ROOT/User/roaring-carla-healthd.timer" "$UNIT_DIR/roaring-carla-healthd.timer"

if [[ ! -e "$CONFIG_DIR/carla-health.env" ]]; then
  install -m 0600 "$ROOT/docs/carla-health.env.example" "$CONFIG_DIR/carla-health.env"
fi

# Retire any legacy long-running observer before installing the oneshot unit.
systemctl --user disable --now roaring-carla-healthd.service >/dev/null 2>&1 || true
systemctl --user stop roaring-carla-healthd.timer >/dev/null 2>&1 || true
systemctl --user daemon-reload

if (( restart_watcher )); then
  if systemctl --user is-active --quiet roaring-carla-watchd.service; then
    systemctl --user restart roaring-carla-watchd.service
    echo "Restarted the existing Carla patch watcher with the pw-link parser."
  else
    echo "The Carla patch watcher is not active; installed the updated script without starting it."
  fi
fi

if (( enable_sampler )); then
  systemctl --user enable --now roaring-carla-healthd.timer
  echo "Enabled intermittent sampling: 8-second capture approximately every 10 minutes."
else
  echo "Installed intermittent sampler; timer remains disabled until explicitly enabled."
fi

echo "Observer config: $CONFIG_DIR/carla-health.env"
echo "Samples store numeric summaries only. No microphone PCM is retained."
echo "Automatic recovery uses a guarded restart and exactly one post-restart verification sample."
