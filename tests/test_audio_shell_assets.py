import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class AudioShellSyntaxTests(unittest.TestCase):
    def test_changed_audio_daemons_parse_as_bash(self):
        scripts = (
            "Bin/roaring_mic_routesd.sh",
            "Bin/roaring_moonlight_micd.sh",
            "Bin/roaring_mic_bussesd.sh",
        )
        for relative in scripts:
            with self.subTest(script=relative):
                result = subprocess.run(
                    ["bash", "-n", str(ROOT / relative)],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_mic_router_uses_hearth_config_and_enforces_carla_bus(self):
        source = (ROOT / "Bin/roaring_mic_routesd.sh").read_text()
        self.assertIn('.config/hearth/roaring_mic_router.conf', source)
        self.assertIn("CARLA_TO_B1", source)
        self.assertIn("CARLA_TO_B2", source)
        self.assertIn("enforce_carla", source)
        self.assertIn("B1_ACTIVE:-true", source)
        self.assertIn("B2_ACTIVE:-true", source)
        self.assertIn("ROARING_MIC_ROUTERD_TEST_MODE", source)
        self.assertIn('"${BASH_SOURCE[0]}" != "$0"', source)
        self.assertIn('if [[ "$ROUTER_TEST_MODE" != "true" ]]; then', source)

    def _run_carla_enforcement(self, graph, *, b1_active, b2_active, carla_b1, carla_b2):
        script_path = ROOT / "Bin/roaring_mic_routesd.sh"
        with tempfile.TemporaryDirectory() as temp_dir:
            calls_path = pathlib.Path(temp_dir) / "pw-link.calls"
            env = os.environ.copy()
            env.update({
                "ROARING_MIC_ROUTERD_TEST_MODE": "1",
                "ROUTER_SCRIPT": str(script_path),
                "CALL_LOG": str(calls_path),
                "GRAPH": graph,
                "B1_ACTIVE": b1_active,
                "B2_ACTIVE": b2_active,
                "CARLA_TO_B1": carla_b1,
                "CARLA_TO_B2": carla_b2,
            })
            shell = r"""
set -euo pipefail
source "$ROUTER_SCRIPT"
pw-cli() {
    printf '%s\n' 'port.alias = "Carla:audio-out1"' 'port.alias = "Carla:audio-out2"'
}
pw-link() { printf '%s\n' "$*" >> "$CALL_LOG"; }
_links_cache="$GRAPH"
enforce_carla
"""
            result = subprocess.run(
                ["bash", "-c", shell],
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return calls_path.read_text().splitlines() if calls_path.exists() else []

    def test_inactive_b1_disconnects_stale_carla_links(self):
        graph = (
            "Carla:audio-out1\n  |-> mic_b1:playback_FL\n"
            "Carla:audio-out2\n  |-> mic_b1:playback_FR\n"
        )
        calls = self._run_carla_enforcement(
            graph,
            b1_active="false",
            b2_active="true",
            carla_b1="true",
            carla_b2="false",
        )
        self.assertEqual(calls, [
            "-d Carla:audio-out1 mic_b1:playback_FL",
            "-d Carla:audio-out2 mic_b1:playback_FR",
        ])

    def test_inactive_b2_disconnects_without_touching_active_b1(self):
        graph = (
            "Carla:audio-out1\n  |-> mic_b1:playback_FL\n  |-> mic_b2:playback_FL\n"
            "Carla:audio-out2\n  |-> mic_b1:playback_FR\n  |-> mic_b2:playback_FR\n"
        )
        calls = self._run_carla_enforcement(
            graph,
            b1_active="true",
            b2_active="false",
            carla_b1="true",
            carla_b2="true",
        )
        self.assertEqual(calls, [
            "-d Carla:audio-out1 mic_b2:playback_FL",
            "-d Carla:audio-out2 mic_b2:playback_FR",
        ])

    def test_enabled_carla_bus_creates_missing_stereo_links(self):
        calls = self._run_carla_enforcement(
            "",
            b1_active="true",
            b2_active="false",
            carla_b1="true",
            carla_b2="false",
        )
        self.assertEqual(calls, [
            "Carla:audio-out1 mic_b1:playback_FL",
            "Carla:audio-out2 mic_b1:playback_FR",
        ])

    def test_sender_defaults_to_b1_and_uses_private_fifo_directory(self):
        source = (ROOT / "Bin/roaring_moonlight_micd.sh").read_text()
        self.assertIn("MIC_SOURCE=", source)
        self.assertIn("b1_mic", source)
        self.assertIn("moonlight-micd.XXXXXX", source)
        self.assertNotIn("$(mktemp -u", source)
        self.assertNotIn("fifo=$(mktemp -u", source)
        self.assertIn("wait_for_peer", source)
        self.assertIn("GLITCH_LIMIT", source)


class Lpd8LayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mixer = (ROOT / "Bin/lpd8_mixer.sh").read_text()
        cls.boot = (ROOT / "Bin/lpd8_boot_defaults.sh").read_text()

    def test_pad_one_controls_only_the_processed_b1_path(self):
        handler = self.mixer.split("handle_pad_index_state() {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn('1)', handler)
        self.assertIn('set_microphone_mute "$mute_state"', handler)
        self.assertIn('MIC_B1_SINK="mic_b1"', self.mixer)
        self.assertIn('MIC_B1_SOURCE="b1_mic"', self.mixer)
        self.assertNotIn('set_mute_source "$(detect_mic_source)"', handler)

    def test_mute_helpers_verify_the_result_instead_of_only_logging_a_send(self):
        sink_helper = self.mixer.split("set_mute_sink() {", 1)[1].split("\n}\n", 1)[0]
        source_helper = self.mixer.split("set_mute_source() {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("pactl get-sink-mute", sink_helper)
        self.assertIn("Mute: $([[", sink_helper)
        self.assertIn("pactl get-source-mute", source_helper)
        self.assertIn("Mute: $([[", source_helper)
        self.assertIn("ERROR: sink mute verification disagreed", sink_helper)
        self.assertIn("ERROR: source mute verification disagreed", source_helper)

    def test_pad_two_mutes_both_headset_endpoints(self):
        handler = self.mixer.split("handle_pad_index_state() {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn('2)', handler)
        self.assertIn('set_headset_mute "$mute_state"', handler)
        self.assertIn('ASTRO_CHAT_SINK="alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-chat"', self.mixer)
        self.assertIn('ASTRO_GAME_SINK="alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-game"', self.mixer)

    def test_all_controller_modes_use_only_the_four_assigned_pads(self):
        cc = self.mixer.split("# A) CC pads", 1)[1].split("# B) Knob CCs", 1)[0]
        program = self.mixer.split("Program Change (press-only", 1)[1].split("# Note On", 1)[0]
        dispatch = self.mixer.split("handle_pad_index_state() {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn('1|2)', cc)
        self.assertIn('3|8)', cc)
        self.assertIn('unassigned CC pad ignored', cc)
        self.assertIn('3|8)', program)
        self.assertIn('1|2)', program)
        self.assertIn('unassigned Program Change pad ignored', program)
        self.assertIn('1)', dispatch)
        self.assertIn('2)', dispatch)
        self.assertIn('3)', dispatch)
        self.assertIn('8)', dispatch)
        for obsolete in ('4)', '5)', '6)', '7)'):
            self.assertNotIn(obsolete, dispatch)

    def test_momentary_action_releases_never_fire_again(self):
        note_off = self.mixer.split("handle_note_off_event() {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn('"$idx" == "3" || "$idx" == "8"', note_off)
        self.assertIn('momentary action pad release ignored', note_off)
        self.assertIn('handle_pad_index_state "$idx" 0', note_off)

    def test_note_cc_and_program_events_drive_the_new_layout(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            home = pathlib.Path(temp_dir)
            (home / ".cache").mkdir()
            (home / ".local/bin").mkdir(parents=True)
            (home / "bin").mkdir()
            show = home / ".local/bin/hearth"
            show.write_text('#!/usr/bin/env bash\nprintf "show\\n" >> "$HOME/actions.log"\n')
            show.chmod(0o755)
            speakers = home / "bin/toggle_scarlett_speakers.sh"
            speakers.write_text('#!/usr/bin/env bash\nprintf "speakers\\n" >> "$HOME/actions.log"\n')
            speakers.chmod(0o755)

            shell = r"""
set -euo pipefail
source <(sed '$d' "$MIXER_SCRIPT")

declare -A sink_mutes=(
  [mic_b1]=no [mic_b2]=no [vm_game]=no [vm_chat]=no [vm_music]=no [vm_share]=no
  [alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-chat]=no
  [alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-game]=no
)
declare -A source_mutes=(
  [b1_mic]=no [b2_mic]=no
  [alsa_input.usb-Focusrite_Scarlett_Solo_USB_Y7XZGYX15C77AB-00.Direct__Direct__source]=no
  [alsa_input.usb-Astro_Gaming_Astro_A50-00.mono-chat]=no
  [sm7b_mono]=no [astro_mic_48k]=no
)

pactl() {
  case "$1" in
    list)
      case "$3" in
        sinks) for name in "${!sink_mutes[@]}"; do printf '1\t%s\n' "$name"; done ;;
        sources) for name in "${!source_mutes[@]}"; do printf '1\t%s\n' "$name"; done ;;
      esac
      ;;
    get-sink-mute) printf 'Mute: %s\n' "${sink_mutes[$2]}" ;;
    get-source-mute) printf 'Mute: %s\n' "${source_mutes[$2]}" ;;
    set-sink-mute)
      value=no; [[ "$3" == 1 || "$3" == yes || "$3" == true ]] && value=yes
      sink_mutes["$2"]="$value"
      ;;
    set-source-mute)
      value=no; [[ "$3" == 1 || "$3" == yes || "$3" == true ]] && value=yes
      source_mutes["$2"]="$value"
      ;;
    *) return 2 ;;
  esac
}

# Keep the test isolated from the real MIDI timing guard/debounce clock.
pads_enabled() { return 0; }
pad_debounced() { return 0; }
load_conf() { :; }

# CC mode: pads 1/2 track the two mute states; action pads fire once on rise.
handle_line 'Control change         0, controller 9, value 127'
[[ "${sink_mutes[mic_b1]}" == yes && "${source_mutes[b1_mic]}" == yes ]]
handle_line 'Control change         0, controller 9, value 0'
[[ "${sink_mutes[mic_b1]}" == no && "${source_mutes[b1_mic]}" == no ]]
handle_line 'Control change         0, controller 10, value 127'
[[ "${sink_mutes[alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-chat]}" == yes ]]
[[ "${sink_mutes[alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-game]}" == yes ]]
handle_line 'Control change         0, controller 10, value 0'
[[ "${sink_mutes[alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-chat]}" == no ]]
[[ "${sink_mutes[alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-game]}" == no ]]
handle_line 'Control change         0, controller 11, value 127'
handle_line 'Control change         0, controller 11, value 0'
handle_line 'Control change         0, controller 8, value 127'
handle_line 'Control change         0, controller 8, value 0'
for cc in 12 13 14 15; do handle_line "Control change         0, controller $cc, value 127"; done

# Program mode: only the two mute pads hold software toggle state, and only
# the two action pads fire. Program values 3-6 are empty physical pads.
handle_line 'Program change         0, program 0'
[[ "${sink_mutes[mic_b1]}" == yes && "${source_mutes[b1_mic]}" == yes ]]
handle_line 'Program change         0, program 0'
[[ "${sink_mutes[mic_b1]}" == no && "${source_mutes[b1_mic]}" == no ]]
handle_line 'Program change         0, program 1'
[[ "${sink_mutes[alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-chat]}" == yes ]]
[[ "${sink_mutes[alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-game]}" == yes ]]
handle_line 'Program change         0, program 1'
[[ "${sink_mutes[alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-chat]}" == no ]]
[[ "${sink_mutes[alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-game]}" == no ]]
for program in 3 4 5 6; do handle_line "Program change         0, program $program"; done
handle_line 'Program change         0, program 2'
handle_line 'Program change         0, program 7'

# Note mode: a later Note-Off toggles mute pads off; releases of momentary
# actions never repeat the action.
handle_line 'Note on                0, note 60, velocity 100'
[[ "${sink_mutes[mic_b1]}" == yes && "${source_mutes[b1_mic]}" == yes ]]
sleep 0.23
handle_line 'Note off               0, note 60'
[[ "${sink_mutes[mic_b1]}" == no && "${source_mutes[b1_mic]}" == no ]]
handle_line 'Note on                0, note 62, velocity 100'
handle_line 'Note off               0, note 62'
handle_line 'Note on                0, note 67, velocity 100'
handle_line 'Note off               0, note 67'

# CC/PROG/NOTE each triggered Show Hearth / speaker exactly once.
[[ "$(grep -c '^show$' "$HOME/actions.log")" == 3 ]]
[[ "$(grep -c '^speakers$' "$HOME/actions.log")" == 3 ]]
"""
            env = os.environ.copy()
            env.update({"HOME": str(home), "MIXER_SCRIPT": str(ROOT / "Bin/lpd8_mixer.sh")})
            result = subprocess.run(
                ["bash", "-c", shell], capture_output=True, text=True, env=env, check=False
            )
            log = (home / ".cache/lpd8-mixer.log").read_text() if (home / ".cache/lpd8-mixer.log").exists() else ""
            self.assertEqual(result.returncode, 0, result.stderr + "\n" + log)

    def test_boot_defaults_cover_mic_headset_and_speaker_mirror(self):
        for endpoint in (
            'mic_b1 mic_b2',
            '"$ASTRO_CHAT" "$ASTRO_GAME" "$SCARLETT_SINK"',
            '"$SCARLETT_INPUT" "$ASTRO_INPUT"',
            'sm7b_mono astro_mic_48k b1_mic b2_mic',
            'ASTRO_CHAT="alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-chat"',
            'ASTRO_GAME="alsa_output.usb-Astro_Gaming_Astro_A50-00.stereo-game"',
            'SCARLETT_SINK="alsa_output.usb-Focusrite_Scarlett_Solo_USB_Y7XZGYX15C77AB-00.Direct__Direct__sink"',
        ):
            self.assertIn(endpoint, self.boot)
        self.assertIn('speaker_mirror_links_ok', self.boot)
        self.assertIn('ROARING_SILENT=1', self.boot)
        self.assertIn('Mute: no', self.boot)

    def test_legacy_audio_control_shows_the_real_hardware_row_order(self):
        source = (ROOT / "Bin/roaring_audio_control.py").read_text()
        start = source.index("PAD_DEFS = [")
        end = source.index("    ]", start) + 5
        definitions = source[start:end]
        labels = [f'"{pad}\\n' for pad in (5, 6, 7, 8, 1, 2, 3, 4)]
        positions = [definitions.index(label) for label in labels]
        self.assertEqual(positions, sorted(positions))
        for obsolete in ("MUSIC", "ASTRO HW", "DEBUG", "MIC SRC"):
            self.assertNotIn(obsolete, definitions)

    def test_boot_unit_is_enabled_and_precedes_the_mixer(self):
        unit = (ROOT / "User/lpd8-boot-defaults.service").read_text()
        drop_in = (ROOT / "User/lpd8-mixer.service.d/boot-defaults.conf").read_text()
        self.assertIn('WantedBy=default.target', unit)
        self.assertIn('After=lpd8-boot-defaults.service', drop_in)
        self.assertIn('roaring-vm-sinks.service', unit)
        self.assertIn('roaring-mic-routesd.service', unit)
        self.assertTrue((ROOT / "User/default.target.wants/lpd8-boot-defaults.service").is_symlink())


if __name__ == "__main__":
    unittest.main()
