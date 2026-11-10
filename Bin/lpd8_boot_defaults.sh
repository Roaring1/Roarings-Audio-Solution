#!/usr/bin/env bash
set -euo pipefail

LOG="$HOME/.cache/lpd8-boot-defaults.log"
mkdir -p "$HOME/.cache"
exec >>"$LOG" 2>&1

log() { printf '[lpd8-boot] %s %s\n' "$(date +%H:%M:%S)" "$*"; }
sink_exists() { pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -Fxq "$1"; }
source_exists() { pactl list short sources 2>/dev/null | awk '{print $2}' | grep -Fxq "$1"; }

# Do not restore saved mute bits from a previous login. Every active VM/mic
# playback bus and live capture source, both headset outputs, and Scarlett
# start ON/unmuted every login. Carla/router processes are left running.
ASTRO_CHAT="alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-chat"
ASTRO_GAME="alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-game"
SCARLETT_SINK="alsa_output.usb-Focusrite_Scarlett_Solo_USB_Y7XZGYX15C77AB-00.Direct__Direct__sink"
SCARLETT_INPUT="alsa_input.usb-Focusrite_Scarlett_Solo_USB_Y7XZGYX15C77AB-00.Direct__Direct__source"
ASTRO_INPUT="alsa_input.usb-Astro_Gaming_Astro_A50-00.mono-chat"
SPEAKER_STATE="$HOME/.cache/roaring_scarlett_loopbacks"
SPEAKER_TOGGLE="$HOME/bin/toggle_scarlett_speakers.sh"
SPEAKER_SOURCES=(vm_game vm_chat vm_music)

# Every active playback bus starts ON, not just the physical headset. That
# ensures a saved mute in one virtual bus cannot make an unmuted headset silent.
AUDIO_SINKS=(
  vm_game vm_chat vm_music vm_share
  mic_b1 mic_b2
  "$ASTRO_CHAT" "$ASTRO_GAME" "$SCARLETT_SINK"
)
# The two live microphone chains are also reset ON. The unrelated LifeCam input
# is intentionally excluded; this is not a blanket enable of every PC device.
MIC_SOURCES=(
  "$SCARLETT_INPUT" "$ASTRO_INPUT"
  sm7b_mono astro_mic_48k b1_mic b2_mic
)

wait_for_audio_paths() {
  local attempts=0 sink source missing
  while (( attempts < 90 )); do
    attempts=$((attempts + 1))
    missing=0
    for sink in "${AUDIO_SINKS[@]}"; do
      sink_exists "$sink" || missing=1
    done
    for source in "${MIC_SOURCES[@]}"; do
      source_exists "$source" || missing=1
    done
    (( missing == 0 )) && return 0
    sleep 0.5
  done
  log "ERROR: one or more audio buses or microphone paths did not appear after $attempts checks; will retry"
  return 1
}

log "waiting for all active playback buses and microphone paths"
wait_for_audio_paths

for sink in "${AUDIO_SINKS[@]}"; do
  pactl set-sink-mute "$sink" 0
  state="$(pactl get-sink-mute "$sink")"
  case "$state" in
    *"Mute: no"*) log "verified unmuted: $sink" ;;
    *) log "ERROR: $sink did not start unmuted ($state)"; exit 1 ;;
  esac
done

for source in "${MIC_SOURCES[@]}"; do
  pactl set-source-mute "$source" 0
  state="$(pactl get-source-mute "$source")"
  case "$state" in
    *"Mute: no"*) log "verified unmuted capture path: $source" ;;
    *) log "ERROR: $source did not start unmuted ($state)"; exit 1 ;;
  esac
done

# The desktop-speaker mirror is also an ON-by-default pad-controlled state.
# Its toggle script mutes Scarlett before adding links, waits for the DMA buffer,
# then unmutes. Keep this a one-time login decision; pad 8 is free to turn it off
# later without the initializer fighting the user during the session.
wait_for_speaker_endpoints() {
  local attempts=0
  while (( attempts < 60 )); do
    attempts=$((attempts + 1))
    if sink_exists "$SCARLETT_SINK" \
      && sink_exists vm_game \
      && sink_exists vm_chat \
      && sink_exists vm_music; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

speaker_mirror_links_ok() {
  local links src channel
  links="$(pw-link -l 2>/dev/null)" || return 1
  for src in "${SPEAKER_SOURCES[@]}"; do
    for channel in FL FR; do
      if ! grep -F -A8 -- "$src:monitor_$channel" <<<"$links" \
        | grep -Fq -- "-> $SCARLETT_SINK:playback_$channel"; then
        return 1
      fi
    done
  done
  [[ -f "$SPEAKER_STATE" ]]
}

if wait_for_speaker_endpoints; then
  if ! speaker_mirror_links_ok; then
    # The marker can survive a PipeWire graph reset. Clear only that stale
    # state marker so the existing safe ON path reattaches and verifies links.
    rm -f "$SPEAKER_STATE"
    if ROARING_SILENT=1 "$SPEAKER_TOGGLE"; then
      attempts=0
      until speaker_mirror_links_ok; do
        attempts=$((attempts + 1))
        (( attempts >= 10 )) && break
        sleep 0.25
      done
    fi
  fi
  if speaker_mirror_links_ok && [[ "$(pactl get-sink-mute "$SCARLETT_SINK")" == *"Mute: no"* ]]; then
    log "verified desktop-speaker mirror ON: game/chat/music connected to Scarlett and unmuted"
  else
    log "WARNING: desktop-speaker mirror could not be verified; pad 8 remains available to enable it"
  fi
else
  log "WARNING: Scarlett or VM speaker sinks did not appear; desktop-speaker mirror left unchanged"
fi

log "boot defaults applied: all VM playback buses, both mic buses/capture chains, headset outputs, and desktop-speaker mirror are ON"
