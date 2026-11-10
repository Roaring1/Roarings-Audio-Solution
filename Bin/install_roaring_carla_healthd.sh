#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$HOME/bin"
UNIT_DIR="$HOME/.config/systemd/user"
CONFIG_DIR="$HOME/.config/roaring"

usage() {
  cat <<'EOF'
Install the Carla health observer and the repaired Carla patch watcher.

Usage:
  install_roaring_carla_healthd.sh [--restart-watcher] [--enable-observer]

Default behavior installs files and reloads user systemd only. The observer
is not enabled or started by default. Its AUTO_RECOVER setting defaults to 0.
EOF
}

restart_watcher=0
enable_observer=0
for arg in "$@"; do
  case "$arg" in
    --restart-watcher) restart_watcher=1 ;;
    --enable-observer) enable_observer=1 ;;
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

if [[ ! -e "$CONFIG_DIR/carla-health.env" ]]; then
  install -m 0600 "$ROOT/docs/carla-health.env.example" "$CONFIG_DIR/carla-health.env"
fi

systemctl --user daemon-reload

if (( restart_watcher )); then
  if systemctl --user is-active --quiet roaring-carla-watchd.service; then
    systemctl --user restart roaring-carla-watchd.service
    echo "Restarted the existing Carla patch watcher with the pw-link parser."
  else
    echo "The Carla patch watcher is not active; installed the updated script without starting it."
  fi
fi

if (( enable_observer )); then
  systemctl --user enable --now roaring-carla-healthd.service
  echo "Enabled the health observer. Automatic Carla recovery remains disabled unless AUTO_RECOVER=1."
else
  echo "Installed the observer unit, but did not start or enable it."
fi

echo "Observer config: $CONFIG_DIR/carla-health.env"
echo "Set AUTO_RECOVER=1 only after validating the detector against real fault and clean speech."
