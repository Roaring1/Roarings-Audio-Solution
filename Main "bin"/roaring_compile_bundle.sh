#!/usr/bin/env bash
set -euo pipefail

# 10/1/2026-1
# Summary: Bundles roaring/lpd8 systemd user units, current-boot logs (per-service), and relevant scripts/configs into ONE line-numbered text file.

OUT="${1:-$HOME/.cache/roaring_bundle_$(date +%Y%m%d_%H%M%S).txt}"
BIN_DIR="$HOME/bin"
UNIT_DIR="$HOME/.config/systemd/user"

mkdir -p "$(dirname "$OUT")"

SERVICES=(
  roaring-audio-routesd.service
  roaring-vm-sinks.service
  roaring-mic-busses.service
  roaring-mic-routesd.service
  lpd8-mixer.service
)

print_hr() {
  echo "################################################################################"
}

print_file() {
  local f="$1"
  print_hr
  echo "FILE: $f"
  echo "--------------------------------------------------------------------------------"
  if [[ -f "$f" || -L "$f" ]]; then
    (ls -l "$f" 2>/dev/null) || true
    (readlink -f "$f" 2>/dev/null) || true
    (stat -c 'size=%s bytes  mtime=%y' "$f" 2>/dev/null || true) || true
    (sha256sum "$f" 2>/dev/null || true) || true
    echo
    if [[ -f "$f" ]]; then
      nl -ba "$f"
    else
      echo "(symlink only; target shown above)"
    fi
  else
    echo "MISSING"
  fi
  echo
}

print_journal() {
  local unit="$1"
  local n="${2:-250}"
  print_hr
  echo "JOURNAL: $unit (current boot, last $n lines, short-iso)"
  echo "--------------------------------------------------------------------------------"
  journalctl --user -u "$unit" --boot --no-pager -n "$n" -o short-iso 2>/dev/null || true
  echo
}

{
  echo "=== roaring bundle ==="
  echo "Time: $(date)"
  echo "Host: $(hostname)"
  echo

  print_hr
  echo "SYSTEMD: matching unit files"
  echo "--------------------------------------------------------------------------------"
  systemctl --user list-unit-files | grep -E 'roaring|lpd8' || true
  echo

  print_hr
  echo "SYSTEMD: status (NO log tail spam)"
  echo "--------------------------------------------------------------------------------"
  systemctl --user status -n 0 --no-pager "${SERVICES[@]}" || true
  echo

  print_hr
  echo "SYSTEMD: unit definitions (systemctl --user cat)"
  echo "--------------------------------------------------------------------------------"
  for s in "${SERVICES[@]}"; do
    echo "### $s"
    systemctl --user cat "$s" 2>/dev/null || echo "MISSING UNIT: $s"
    echo
  done

  print_hr
  echo "SYSTEMD: useful properties (restart / exit / limits)"
  echo "--------------------------------------------------------------------------------"
  for s in "${SERVICES[@]}"; do
    echo "### $s"
    systemctl --user show "$s" \
      -p Id -p ActiveState -p SubState -p ExecMainPID -p ExecMainCode -p ExecMainStatus \
      -p NRestarts -p Restart -p RestartUSec \
      -p StartLimitIntervalUSec -p StartLimitBurst -p Result \
      2>/dev/null || true
    echo
  done

  print_hr
  echo "BIN: symlink sanity (roaring_*d.sh)"
  echo "--------------------------------------------------------------------------------"
  ls -l "$BIN_DIR"/roaring_*d.sh 2>/dev/null || true
  echo
  readlink -f \
    "$BIN_DIR/roaring_audio_routesd.sh" \
    "$BIN_DIR/roaring_mic_routesd.sh" \
    "$BIN_DIR/roaring_mic_bussesd.sh" \
    "$BIN_DIR/roaring_audio_stackd.sh" \
    2>/dev/null || true
  echo

  print_hr
  echo "JOURNAL: per-service sections (keeps chronology sane)"
  echo "--------------------------------------------------------------------------------"
  echo "Note: Each service section is chronological. All sections are current-boot only (--boot)."
  echo
  for s in "${SERVICES[@]}"; do
    print_journal "$s" 300
  done

  print_hr
  echo "FILES: relevant scripts (exclude .save)"
  echo "--------------------------------------------------------------------------------"
  find "$BIN_DIR" -maxdepth 1 -type f \
    \( -name 'roaring*.sh' -o -name 'lpd8*.sh' -o -name 'toggle*.sh' -o -name '*.py' \) \
    ! -name '*.save' \
    -print0 \
  | sort -z \
  | while IFS= read -r -d '' f; do
      print_file "$f"
    done

  print_hr
  echo "FILES: relevant configs"
  echo "--------------------------------------------------------------------------------"
  print_file "$HOME/.config/roaring_mixer.conf"
  print_file "$HOME/.config/roaring_mic_router.conf"

  if [[ -d "$HOME/.config/roaring_audio" ]]; then
    find "$HOME/.config/roaring_audio" -maxdepth 2 -type f -print0 \
    | sort -z \
    | while IFS= read -r -d '' f; do
        print_file "$f"
      done
  fi

  if [[ -d "$HOME/.config/pipewire/pipewire-pulse.conf.d" ]]; then
    find "$HOME/.config/pipewire/pipewire-pulse.conf.d" -maxdepth 1 -type f -name '*.conf' -print0 \
    | sort -z \
    | while IFS= read -r -d '' f; do
        print_file "$f"
      done
  fi

} > "$OUT"

echo "$OUT"
