#!/usr/bin/env bash
set -euo pipefail

# 10/1/2026-7
# Summary:
# - One-button reset for the whole Roaring audio stack.
# - Strong pre_mute/post_mute to reduce scratches on HARD restarts.
# - Captures which MPRIS players were Playing and resumes them after restart.
# - Tries to restart Carla session via roaring-carla-session.service.
# - Starts roaring-carla-patch.service after Carla to fix sm7b_mono->Carla links.
# - Does NOT attempt pactl unload-module (PipeWire-Pulse often denies it).
# - notify-send popups only contain end-user messages (no debug spam).

MODE="hard"
DISABLE_AUTOREFRESH="yes"
RESUME_MEDIA="yes"
TRY_CARLA="yes"
DUMP_ON_RESTART="yes"
PROMPT_CARLA="yes"
RESUME_DISCORD="yes"
CARLA_MODE_OVERRIDE=""
SCARLETT_MIRROR_STATE="$HOME/.cache/roaring_scarlett_loopbacks"
TOGGLE_SCARLETT="$HOME/bin/toggle_scarlett_speakers.sh"
CARLA_MODE_FILE="$HOME/.config/roaring/carla_mode"

# Best-effort: avoid low per-shell FD limits for pactl/journal usage.
ulimit -n 1048576 2>/dev/null || true

for a in "${@:-}"; do
  case "$a" in
    --soft) MODE="soft" ;;
    --hard) MODE="hard" ;;
    --no-disable-autorefresh) DISABLE_AUTOREFRESH="no" ;;
    --no-resume-media) RESUME_MEDIA="no" ;;
    --no-carla) TRY_CARLA="no" ;;
    --no-dump) DUMP_ON_RESTART="no" ;;
    --no-prompt-carla) PROMPT_CARLA="no" ;;
    --prompt-carla) PROMPT_CARLA="yes" ;;
    --no-discord) RESUME_DISCORD="no" ;;
    --patchbay) CARLA_MODE_OVERRIDE="patchbay" ;;
    --no-patchbay) CARLA_MODE_OVERRIDE="rack" ;;
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
  "roaring-moonlight-mic.service"
)

PIPEWIRE_UNITS=(
  "wireplumber.service"
  "pipewire.service"
  "pipewire-pulse.service"
)

CARLA_UNIT="roaring-carla-session.service"

# Astro target (config override via roaring_mixer.conf)
CONF="$HOME/.config/roaring_mixer.conf"
DEFAULT_ASTRO_TARGET="${ASTRO_TARGET:-alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-chat}"
ASTRO_TARGET="$DEFAULT_ASTRO_TARGET"

# Fade tuning (these are the knobs that control “scratchiness”)
FADE_MS=260
FADE_STEPS=13
SETTLE_AFTER_MUTE_MS=220
SETTLE_AFTER_PIPEWIRE_MS=700
SETTLE_BEFORE_RESTORE_MS=700

log() { echo "[restart-everything] $(date +'%H:%M:%S') $*"; }

notify() {
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send "Roaring Audio" "$1" >/dev/null 2>&1 || true
}

msleep() {
  local ms="$1"
  usleep $(( ms * 1000 )) 2>/dev/null || sleep "$(awk "BEGIN{print $ms/1000}")"
}

wait_for_pactl() { until pactl info >/dev/null 2>&1; do sleep 0.2; done; }

sink_exists() {
  local s="$1"
  pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$s"
}

get_sink_mute() { pactl get-sink-mute "$1" 2>/dev/null | awk '{print $2}' || echo "unknown"; }
get_sink_pct()  { pactl get-sink-volume "$1" 2>/dev/null | grep -oE '[0-9]+%' | head -n 1 | tr -d '%' || echo ""; }

set_sink_pct()  { pactl set-sink-volume "$1" "${2}%" >/dev/null 2>&1 || true; }
set_sink_mute() { pactl set-sink-mute   "$1" "$2"     >/dev/null 2>&1 || true; }

load_conf() {
  ASTRO_TARGET="$DEFAULT_ASTRO_TARGET"
  if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF"
  fi
}

fade_sink_to() {
  local sink="$1" from="$2" to="$3"
  [[ -n "$from" && -n "$to" ]] || return 0
  [[ "$from" =~ ^[0-9]+$ && "$to" =~ ^[0-9]+$ ]] || return 0

  local steps="$FADE_STEPS"
  (( steps < 1 )) && steps=1

  local step_ms=$(( FADE_MS / steps ))
  (( step_ms < 5 )) && step_ms=5

  for ((i=1; i<=steps; i++)); do
    local pct=$(( from + ( (to - from) * i ) / steps ))
    (( pct < 0 )) && pct=0
    (( pct > 150 )) && pct=150
    set_sink_pct "$sink" "$pct"
    msleep "$step_ms"
  done
}

wait_pipewire_stack_active() {
  local i=0
  until systemctl --user is-active -q pipewire.service && systemctl --user is-active -q wireplumber.service; do
    ((i++)) || true
    if (( i > 80 )); then
      log "pipewire/wireplumber not reporting active yet; continuing anyway."
      return 0
    fi
    sleep 0.1
  done
}

stop_everything() {
  log "Stopping Roaring services + autorefresh..."
  systemctl --user stop "${ROARING_UNITS[@]}" >/dev/null 2>&1 || true
}

carla_unit_exists() { systemctl --user cat "$CARLA_UNIT" >/dev/null 2>&1; }
carla_unit_active() { systemctl --user is-active -q "$CARLA_UNIT"; }
carla_proc_running() {
  # Match only the real Carla python3 process, not the bwrap wrappers.
  # bwrap processes also carry the .carxp path in their argv, causing false positives.
  pgrep -f '/app/share/carla/carla' >/dev/null 2>&1 ||
    pgrep -f '/usr/share/carla/carla' >/dev/null 2>&1 ||
    pgrep -f 'carla-rack' >/dev/null 2>&1
}

log_carla_state() {
  local unit="no" active="no" proc="no"
  carla_unit_exists && unit="yes"
  carla_unit_active && active="yes"
  carla_proc_running && proc="yes"
  log "carla state: unit=${unit} active=${active} proc=${proc}"
}

stop_carla_process() {
  if carla_proc_running; then
    log "carla stop: proc"
    # Kill the real python3 Carla process first, then clean up bwrap wrappers.
    # Killing bwrap first can orphan the python process or cause unclean shutdown.
    pkill -TERM -f '/app/share/carla/carla'   >/dev/null 2>&1 || true
    pkill -TERM -f '/usr/share/carla/carla'   >/dev/null 2>&1 || true
    pkill -TERM -f 'carla-rack'               >/dev/null 2>&1 || true
    pkill -TERM -f 'CarlaProject_Roaring\.carxp' >/dev/null 2>&1 || true
    local i=0
    while carla_proc_running; do
      ((i++)) || true
      if (( i > 20 )); then
        log "carla stop: sigkill"
        pkill -KILL -f '/app/share/carla/carla'      >/dev/null 2>&1 || true
        pkill -KILL -f 'CarlaProject_Roaring\.carxp' >/dev/null 2>&1 || true
        pkill -KILL -f 'carla-rack'                  >/dev/null 2>&1 || true
        break
      fi
      msleep 200
    done
  fi
}

stop_carla_if_requested() {
  [[ "$TRY_CARLA" == "yes" ]] || return 0
  log_carla_state
  if carla_unit_exists; then
    log "carla stop: unit"
    systemctl --user stop "$CARLA_UNIT" >/dev/null 2>&1 || true
    stop_carla_process
    log_carla_state
    return 0
  fi

  if command -v carla >/dev/null 2>&1; then
    stop_carla_process
    log_carla_state
    return 0
  fi

  log "carla stop: not found"
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

start_roaring_stack() {
  log "Starting Roaring services..."
  systemctl --user start \
    "roaring-vm-sinks.service" \
    "roaring-mic-busses.service" \
    "roaring-mic-routesd.service" \
    "roaring-audio-routesd.service" \
    "lpd8-mixer.service" \
    "roaring-moonlight-mic.service" >/dev/null 2>&1 || true
}

# -------- media resume --------
_PLAYING_PLAYERS=()
_SPOTIFY_WAS_RUNNING="no"
_SPOTIFY_CMD=""
_DISCORD_WAS_RUNNING="no"
_DISCORD_CMD=""

pre_media() {
  [[ "$RESUME_MEDIA" == "yes" ]] || return 0
  command -v playerctl >/dev/null 2>&1 || return 0

  _PLAYING_PLAYERS=()
  while read -r p; do
    [[ -n "${p:-}" ]] || continue
    local st
    st="$(playerctl --player="$p" status 2>/dev/null || true)"
    if [[ "$st" == "Playing" ]]; then
      _PLAYING_PLAYERS+=("$p")
    fi
  done < <(playerctl -l 2>/dev/null || true)
}

post_media() {
  [[ "$RESUME_MEDIA" == "yes" ]] || return 0
  command -v playerctl >/dev/null 2>&1 || return 0
  (( ${#_PLAYING_PLAYERS[@]} > 0 )) || return 0

  msleep 800
  for p in "${_PLAYING_PLAYERS[@]}"; do
    playerctl --player="$p" play >/dev/null 2>&1 || true
  done
}
# --------------------------------

detect_discord_cmd() {
  if command -v discord >/dev/null 2>&1; then
    _DISCORD_CMD="discord"
    return 0
  fi
  if command -v flatpak >/dev/null 2>&1 && flatpak info -q com.discordapp.Discord >/dev/null 2>&1; then
    _DISCORD_CMD="flatpak run com.discordapp.Discord"
    return 0
  fi
  _DISCORD_CMD=""
}

pre_discord() {
  [[ "$RESUME_DISCORD" == "yes" ]] || return 0
  _DISCORD_WAS_RUNNING="no"
  detect_discord_cmd
  if pgrep -x Discord >/dev/null 2>&1 || pgrep -x discord >/dev/null 2>&1 || pgrep -f com.discordapp.Discord >/dev/null 2>&1; then
    _DISCORD_WAS_RUNNING="yes"
  fi
  if [[ "$_DISCORD_WAS_RUNNING" == "yes" ]]; then
    log "Discord detected; will quick-restart after audio reset."
  elif [[ -z "$_DISCORD_CMD" ]]; then
    log "Discord not found; skipping app restart."
  fi
}

post_discord() {
  [[ "$RESUME_DISCORD" == "yes" ]] || return 0
  [[ "$_DISCORD_WAS_RUNNING" == "yes" ]] || return 0
  [[ -n "$_DISCORD_CMD" ]] || return 0

  log "Restarting Discord..."
  pkill -TERM -x Discord >/dev/null 2>&1 || true
  pkill -TERM -x discord >/dev/null 2>&1 || true
  pkill -TERM -f com.discordapp.Discord >/dev/null 2>&1 || true
  msleep 500
  nohup $_DISCORD_CMD >/dev/null 2>&1 &
}

detect_spotify_cmd() {
  if command -v spotify >/dev/null 2>&1; then
    _SPOTIFY_CMD="spotify"
    return 0
  fi
  if command -v flatpak >/dev/null 2>&1 && flatpak info -q com.spotify.Client >/dev/null 2>&1; then
    _SPOTIFY_CMD="flatpak run com.spotify.Client"
    return 0
  fi
  _SPOTIFY_CMD=""
}

pre_spotify() {
  _SPOTIFY_WAS_RUNNING="no"
  detect_spotify_cmd
  if pgrep -x spotify >/dev/null 2>&1 || pgrep -f com.spotify.Client >/dev/null 2>&1; then
    _SPOTIFY_WAS_RUNNING="yes"
  fi
  if [[ "$_SPOTIFY_WAS_RUNNING" == "yes" ]]; then
    log "Spotify detected; will quick-restart after audio reset."
  elif [[ -z "$_SPOTIFY_CMD" ]]; then
    log "Spotify not found; skipping app restart."
  fi
}

post_spotify() {
  [[ "$_SPOTIFY_WAS_RUNNING" == "yes" ]] || return 0
  [[ -n "$_SPOTIFY_CMD" ]] || return 0

  log "Restarting Spotify..."
  pkill -TERM -x spotify >/dev/null 2>&1 || true
  pkill -TERM -f com.spotify.Client >/dev/null 2>&1 || true
  msleep 500
  nohup $_SPOTIFY_CMD >/dev/null 2>&1 &
}

prompt_carla_restart() {
  [[ "$PROMPT_CARLA" == "yes" ]] || return 0
  [[ -t 0 ]] || return 0

  local ans=""
  read -r -t 5 -p "Restart Carla? (y/n or 1/2) [auto-no in 5s]: " ans || ans=""
  case "${ans,,}" in
    y|yes|1) TRY_CARLA="yes" ;;
    n|no|2|"") TRY_CARLA="no" ;;
    *) TRY_CARLA="no" ;;
  esac
}

apply_carla_mode_override() {
  [[ -n "$CARLA_MODE_OVERRIDE" ]] || return 0
  mkdir -p "$(dirname "$CARLA_MODE_FILE")"
  printf '%s\n' "$CARLA_MODE_OVERRIDE" > "$CARLA_MODE_FILE"
  log "carla mode: ${CARLA_MODE_OVERRIDE}"
}

restart_carla_best_effort() {
  [[ "$TRY_CARLA" == "yes" ]] || return 0

  log_carla_state

  # Wait for the PipeWire audio graph to be usable before starting Carla.
  # roaring-vm-sinks creates vm_game/vm_chat; Carla needs them to patch its
  # plugins.  Starting too early (e.g. at 500ms after PW restart) leaves Carla
  # with no sinks to connect to, causing plugins to disconnect permanently.
  wait_for_pactl
  local t=0
  until sink_exists "vm_game" && sink_exists "vm_chat"; do
    ((t++)) || true
    if (( t > 50 )); then
      log "carla start: vm_game/vm_chat not ready after 5s; starting anyway"
      break
    fi
    msleep 100
  done
  log "carla start: sinks ready after ~$((t*100))ms"

  if carla_unit_exists; then
    notify "Restarting Carla session…"
    log "carla start: unit"
    systemctl --user reset-failed "$CARLA_UNIT" >/dev/null 2>&1 || true
    if carla_unit_active; then
      systemctl --user restart "$CARLA_UNIT" >/dev/null 2>&1 || true
    else
      systemctl --user start "$CARLA_UNIT" >/dev/null 2>&1 || true
    fi
    if carla_unit_active; then
      log_carla_state
      systemctl --user reset-failed roaring-carla-patch.service >/dev/null 2>&1 || true
      systemctl --user start roaring-carla-patch.service >/dev/null 2>&1 || true
      log "carla-patch: started"
      return 0
    fi
    log "carla start: unit inactive; fallback"
  fi

  if command -v carla >/dev/null 2>&1; then
    notify "Restarting Carla…"
    log "carla start: direct"
    if ! carla_proc_running; then
      local carxp=""
      carxp="$(systemctl --user cat "$CARLA_UNIT" 2>/dev/null | grep -oE '(\\$HOME[^" ]+\.carxp|/[A-Za-z0-9._/-]+\.carxp)' | head -n 1 || true)"
      if [[ "$carxp" == \$HOME* ]]; then
        carxp="${carxp/\$HOME/$HOME}"
      fi
      if [[ -n "$carxp" && -f "$carxp" ]]; then
        log "carla start: project=$(basename "$carxp")"
        if [[ -f "$CARLA_MODE_FILE" ]] && [[ "$(cat "$CARLA_MODE_FILE" 2>/dev/null || true)" == "patchbay" ]]; then
          nohup carla "$carxp" >/dev/null 2>&1 &
        else
          nohup carla-rack "$carxp" >/dev/null 2>&1 &
        fi
      else
        log "carla start: no project"
        if [[ -f "$CARLA_MODE_FILE" ]] && [[ "$(cat "$CARLA_MODE_FILE" 2>/dev/null || true)" == "patchbay" ]]; then
          nohup carla >/dev/null 2>&1 &
        else
          nohup carla-rack >/dev/null 2>&1 &
        fi
      fi
    fi
    log_carla_state
    return 0
  fi

  log "carla start: not found"
}

_PRE_ASTRO_MUTE=""
_PRE_ASTRO_PCT=""
_PRE_DEF_MUTE=""
_PRE_DEF_PCT=""
_ASTRO_PRESENT="no"
_SCARLETT_MIRROR_WAS_ON="no"

pre_mute() {
  command -v pactl >/dev/null 2>&1 || return 0
  wait_for_pactl

  local def="@DEFAULT_SINK@"

  _PRE_DEF_MUTE="$(get_sink_mute "$def")"
  _PRE_DEF_PCT="$(get_sink_pct "$def")"

  _ASTRO_PRESENT="no"
  if sink_exists "$ASTRO_TARGET"; then
    _ASTRO_PRESENT="yes"
    _PRE_ASTRO_MUTE="$(get_sink_mute "$ASTRO_TARGET")"
    _PRE_ASTRO_PCT="$(get_sink_pct "$ASTRO_TARGET")"
  fi

  log "pre_mute: default_sink mute=${_PRE_DEF_MUTE} vol=${_PRE_DEF_PCT}% | astro_present=${_ASTRO_PRESENT}"

  [[ -n "${_PRE_DEF_PCT:-}" ]] && fade_sink_to "$def" "${_PRE_DEF_PCT}" 0
  if [[ "$_ASTRO_PRESENT" == "yes" ]] && [[ -n "${_PRE_ASTRO_PCT:-}" ]]; then
    fade_sink_to "$ASTRO_TARGET" "${_PRE_ASTRO_PCT}" 0
  fi

  set_sink_pct "$def" 0
  set_sink_mute "$def" 1
  if [[ "$_ASTRO_PRESENT" == "yes" ]]; then
    set_sink_pct "$ASTRO_TARGET" 0
    set_sink_mute "$ASTRO_TARGET" 1
  fi

  msleep "$SETTLE_AFTER_MUTE_MS"
}

post_mute() {
  command -v pactl >/dev/null 2>&1 || return 0
  wait_for_pactl

  local def="@DEFAULT_SINK@"
  msleep "$SETTLE_BEFORE_RESTORE_MS"

  set_sink_pct "$def" 0
  set_sink_mute "$def" 1
  if [[ "$_ASTRO_PRESENT" == "yes" ]] && sink_exists "$ASTRO_TARGET"; then
    set_sink_pct "$ASTRO_TARGET" 0
    set_sink_mute "$ASTRO_TARGET" 1
  fi

  if [[ -n "${_PRE_DEF_PCT:-}" ]]; then
    fade_sink_to "$def" 0 "$_PRE_DEF_PCT"
  fi
  if [[ "$_ASTRO_PRESENT" == "yes" ]] && sink_exists "$ASTRO_TARGET" && [[ -n "${_PRE_ASTRO_PCT:-}" ]]; then
    fade_sink_to "$ASTRO_TARGET" 0 "$_PRE_ASTRO_PCT"
  fi

  if [[ "${_PRE_DEF_MUTE:-}" == "yes" ]]; then set_sink_mute "$def" 1; fi
  if [[ "${_PRE_DEF_MUTE:-}" == "no"  ]]; then set_sink_mute "$def" 0; fi

  if [[ "$_ASTRO_PRESENT" == "yes" ]] && sink_exists "$ASTRO_TARGET"; then
    if [[ "${_PRE_ASTRO_MUTE:-}" == "yes" ]]; then set_sink_mute "$ASTRO_TARGET" 1; fi
    if [[ "${_PRE_ASTRO_MUTE:-}" == "no"  ]]; then set_sink_mute "$ASTRO_TARGET" 0; fi
  fi

  log "post_mute: restored"
}

main() {
  notify "Restarting audio stack (${MODE})…"

  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user reset-failed  >/dev/null 2>&1 || true

  load_conf
  apply_carla_mode_override
  if [[ -s "$SCARLETT_MIRROR_STATE" ]]; then
    _SCARLETT_MIRROR_WAS_ON="yes"
    log "scarlett mirror: was on (state file present)"
  fi
  pre_media
  pre_discord
  pre_spotify
  prompt_carla_restart
  pre_mute

  stop_carla_if_requested
  stop_everything
  disable_autorefresh_if_requested

  if [[ "$MODE" == "hard" ]]; then
    restart_pipewire_stack
    wait_pipewire_stack_active
    msleep "$SETTLE_AFTER_PIPEWIRE_MS"
  fi

  start_roaring_stack
  msleep 350

  # Force default audio source to b1_mic (Carla-processed mic) instead of b2_mic.
  # WirePlumber may restore b2_mic from state if it was ever the last default.
  local b1_id
  b1_id="$(wpctl status 2>/dev/null | grep -E '\bb1_mic\b' | grep -oE '[0-9]+\.' | head -1 | tr -d '.' || true)"
  if [[ -n "$b1_id" ]]; then
    wpctl set-default "$b1_id" >/dev/null 2>&1 && log "default source: b1_mic (id=$b1_id)" || true
  else
    log "default source: b1_mic not found yet, skipping"
  fi

  restart_carla_best_effort
  post_discord
  post_spotify

  if [[ "$_SCARLETT_MIRROR_WAS_ON" == "yes" ]] && [[ -x "$TOGGLE_SCARLETT" ]]; then
    log "scarlett mirror: restoring"
    "$TOGGLE_SCARLETT" >/dev/null 2>&1 || true
  fi

  post_mute
  post_media

  notify "Audio stack restarted."

  if [[ "$DUMP_ON_RESTART" == "yes" ]]; then
    if [[ -x "$HOME/bin/roaring_audio_debug_dump.sh" ]]; then
      log "dump: start"
      "$HOME/bin/roaring_audio_debug_dump.sh" >/dev/null 2>&1 || true
      log "dump: done"
    else
      log "dump: missing"
    fi
  fi

  log "Done. Quick status:"
  systemctl --user --no-pager --full status \
    roaring-vm-sinks.service \
    roaring-mic-busses.service \
    roaring-mic-routesd.service \
    roaring-audio-routesd.service \
    lpd8-mixer.service || true
}

main
