#!/usr/bin/env bash
set -euo pipefail

# Carla's JACK client can request its automatic 1024-frame quantum at startup.
# Once its node exists, set the graph target explicitly. The sender's live xrun
# monitor may raise this to 1024 for recovery; a future Carla restart returns
# the system to this known-good 512-frame baseline.
target="$(printenv ROARING_CARLA_QUANTUM 2>/dev/null || true)"
[[ -n "$target" ]] || target=512
case "$target" in
  512|1024) ;;
  *)
    echo "carla-post: invalid graph quantum '$target'; using safe default 512" >&2
    target=512
    ;;
esac

for attempt in $(seq 1 120); do
  if pw-cli ls Node 2>/dev/null | grep -Fq 'node.name = "Carla"'; then
    break
  fi
  sleep 0.25
done

if ! pw-cli ls Node 2>/dev/null | grep -Fq 'node.name = "Carla"'; then
  echo "carla-post: Carla node not found; leaving PipeWire policy unchanged" >&2
  exit 0
fi

if ! pw-metadata -n settings 0 clock.force-quantum "$target" >/dev/null 2>&1; then
  echo "carla-post: could not set graph quantum $target; leaving current policy unchanged" >&2
  exit 0
fi

for attempt in $(seq 1 20); do
  settings="$(pw-metadata -n settings 2>/dev/null || true)"
  forced="$(printf '%s\n' "$settings" |
    sed -n "s/.*key:'clock.force-quantum' value:'\([0-9][0-9]*\)'.*/\1/p" | tail -n1)"
  if [[ "$forced" == "$target" ]]; then
    echo "carla-post: Carla ready; forced PipeWire graph quantum to $target frames at 48 kHz"
    exit 0
  fi
  sleep 0.25
done

echo "carla-post: requested graph quantum $target but metadata did not confirm it" >&2
exit 0
