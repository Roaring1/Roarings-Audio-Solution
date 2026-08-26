#!/usr/bin/env bash
# roaring_vesktop_minecraft_watchd.sh  v1.0
# Thin wrapper so this watchdog follows the same naming/logging convention
# as roaring_vesktop_mic_watchd.sh / roaring_vesktop_stream_watchd.sh.
# Actual logic lives in roaring_vesktop_minecraft_rpc.py (needs psutil,
# which is already importable system-wide on this host).
exec python3 "$(dirname "$0")/roaring_vesktop_minecraft_rpc.py"
