#!/usr/bin/env bash
set -euo pipefail

# Run from Carla's systemd ExecStartPre. Ignore this helper and all ancestors.
carla_pids() {
  local proc_root proc_dir pid current parent cmd ancestors_file
  proc_root="$(printenv ROARING_CARLA_PROC_ROOT 2>/dev/null || true)"
  [[ -n "$proc_root" ]] || proc_root="/proc"
  ancestors_file="$(mktemp)" || return 1

  current=$$
  while [[ "$current" =~ ^[0-9]+$ ]] && (( current > 1 )); do
    printf '%s\n' "$current" >> "$ancestors_file"
    [[ -r "$proc_root/$current/status" ]] || break
    parent="$(awk '/^PPid:/{print $2}' "$proc_root/$current/status" 2>/dev/null || true)"
    [[ "$parent" =~ ^[0-9]+$ ]] || break
    current="$parent"
  done

  for proc_dir in "$proc_root"/[0-9]*; do
    [[ -r "$proc_dir/cmdline" ]] || continue
    pid="$(basename "$proc_dir")"
    grep -qx "$pid" "$ancestors_file" && continue
    cmd="$(tr '\0' ' ' < "$proc_dir/cmdline" 2>/dev/null || true)"
    case "$cmd" in
      /usr/bin/python3\ /app/share/carla/carla\ *|/usr/bin/python3.13\ /app/share/carla/carla\ *|/usr/bin/python3.12\ /app/share/carla/carla\ *)
        printf '%s\n' "$pid"
        ;;
    esac
  done
  rm -f "$ancestors_file"
}

stale_pids="$(carla_pids)"
if [[ -z "$stale_pids" ]]; then
  echo "carla-pre: no stale Carla backend"
  exit 0
fi

echo "carla-pre: stopping stale Carla backend PID(s): $stale_pids"
while IFS= read -r pid; do
  [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
done <<< "$stale_pids"

for _ in $(seq 1 25); do
  alive=0
  while IFS= read -r pid; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      alive=1
    fi
  done <<< "$stale_pids"
  (( alive == 0 )) && break
  sleep 0.2
done

while IFS= read -r pid; do
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "carla-pre: force-stopping unresponsive Carla backend PID $pid"
    kill -KILL "$pid" 2>/dev/null || true
  fi
done <<< "$stale_pids"
echo "carla-pre: stale Carla backend cleared"
