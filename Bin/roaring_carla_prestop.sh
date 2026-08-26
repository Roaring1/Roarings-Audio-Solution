#!/usr/bin/env bash
# roaring_carla_prestop.sh
# Called by roaring-carla-session.service ExecStartPre to kill any stale Carla
# instance before a fresh launch.
#
# WHY A SEPARATE FILE (not inline bash -c '...'):
#   When systemd runs ExecStartPre as `bash -c '<script text>'`, the entire
#   script text becomes part of the bash process's /proc/$pid/cmdline.  Any
#   pattern used with `pkill -f` will also match that bash process, causing
#   the script to kill itself before completing.  Running as a real file means
#   the bash cmdline is only `bash /path/to/this_script.sh` — it contains no
#   Carla-related strings, so pkill cannot accidentally self-match.

set -euo pipefail

MYPID=$$

# Find pids matching the carxp project path, excluding this script's own pid.
# Match /app/share/carla/carla (real python3 process) not .carxp path.
# The .carxp path also appears in bwrap wrapper processes — matching it
# gives false positives (3 pids for 1 Carla instance).
_carla_pids() {
  { pgrep -f '/app/share/carla/carla' 2>/dev/null;
    pgrep -f '/usr/share/carla/carla' 2>/dev/null; } | sort -u || true
}

pids=$(_carla_pids)

if [[ -n "$pids" ]]; then
  echo "carla-pre: stale Carla found (pids: $(echo "$pids" | tr '\n' ' ')) — sending SIGTERM"
  echo "$pids" | xargs -r kill -TERM 2>/dev/null || true
  sleep 2
  # Check if anything survived
  pids=$(_carla_pids)
  if [[ -n "$pids" ]]; then
    echo "carla-pre: still alive after TERM — sending SIGKILL"
    echo "$pids" | xargs -r kill -KILL 2>/dev/null || true
  fi
  echo "carla-pre: stale instance cleared"
else
  echo "carla-pre: no stale Carla — clean start"
fi
