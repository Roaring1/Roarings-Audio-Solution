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

    def test_sender_selects_graph_aware_capture_fragment(self):
        script_path = ROOT / "Bin/roaring_moonlight_micd.sh"
        cases = (
            ("128", "0", "", "0", "480"),
            ("256", "0", "", "0", "480"),
            ("512", "0", "", "0", "960"),
            ("1024", "0", "", "0", "960"),
            ("2048", "0", "", "0", "1920"),
            ("unknown", "0", "", "0", "960"),
            ("1024", "256", "", "0", "480"),
            ("1024", "512", "", "0", "960"),
            ("1024", "0", "768", "0", "768"),
            ("1024", "0", "241", "0", "960"),
            ("1024", "0", "0480", "0", "480"),
            ("256", "0", "", "1", "1920"),
        )
        for quantum, forced, override, fallback, expected in cases:
            with self.subTest(quantum=quantum, forced=forced, override=override, fallback=fallback):
                env = os.environ.copy()
                env.update({
                    "SCRIPT_PATH": str(script_path),
                    "TEST_QUANTUM": quantum,
                    "TEST_FORCE": forced,
                    "TEST_OVERRIDE": override,
                    "TEST_FALLBACK": fallback,
                })
                shell = r"""set -euo pipefail
RATE=48000
PULSE_FRAGMENT_OVERRIDE="$TEST_OVERRIDE"
PULSE_FRAGMENT_BYTES=1920
PULSE_FRAGMENT_FALLBACK="$TEST_FALLBACK"
PULSE_FRAGMENT_MAX=1920
log() { :; }
pw-metadata() {
  if [[ "$TEST_QUANTUM" != unknown ]]; then
    printf "update: id:0 key:'clock.quantum' value:'%s' type:''\\n" "$TEST_QUANTUM"
  fi
  printf "update: id:0 key:'clock.force-quantum' value:'%s' type:''\\n" "$TEST_FORCE"
}
source <(sed -n '/^pipewire_quantum() {/,/^}/p' "$SCRIPT_PATH")
source <(sed -n '/^select_capture_fragment() {/,/^}/p' "$SCRIPT_PATH")
select_capture_fragment
printf '%s' "$PULSE_FRAGMENT_BYTES"
"""
                result = subprocess.run(
                    ["bash", "-c", shell],
                    capture_output=True,
                    text=True,
                    env=env,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)

    def test_carla_launcher_supports_headless_and_patchbay_modes(self):
        script_path = ROOT / "Bin/roaring_carla_launch.sh"
        source = script_path.read_text()
        self.assertIn('CARLA_MODE="headless"', source)
        self.assertIn('CARLA_MODE" == "patchbay"', source)
        self.assertIn('ROARING_CARLA_GUI:-0', source)
        with tempfile.TemporaryDirectory() as temp_dir:
            home = pathlib.Path(temp_dir)
            (home / ".config/roaring").mkdir(parents=True)
            fake_bin = home / "bin"
            fake_bin.mkdir()
            log = home / "flatpak-args"
            fake_flatpak = fake_bin / "flatpak"
            fake_flatpak.write_text(
                '#!/bin/sh\n'
                'if [ "$1" = "run" ]; then printf "%s\\n" "$*" > "$FLATPAK_ARGS_LOG"; fi\n'
                'exit 0\n'
            )
            fake_flatpak.chmod(0o755)
            fake_pgrep = fake_bin / "pgrep"
            fake_pgrep.write_text("#!/bin/sh\nexit 1\n")
            fake_pgrep.chmod(0o755)
            fake_proc = home / "proc"
            fake_proc.mkdir()
            env = os.environ.copy()
            env.update({
                "HOME": str(home),
                "PATH": str(fake_bin) + os.pathsep + env.get("PATH", ""),
                "FLATPAK_ARGS_LOG": str(log),
                "ROARING_CARLA_PROC_ROOT": str(fake_proc),
            })
            project = str(home / "project.carxp")
            mode_path = home / ".config/roaring/carla_mode"
            mode_path.write_text("headless\n")
            run = subprocess.run(
                ["bash", str(script_path), project], env=env,
                capture_output=True, text=True, check=False
            )
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn("studio.kx.carla --no-gui", log.read_text())
            mode_path.write_text("patchbay\n")
            run = subprocess.run(
                ["bash", str(script_path), project], env=env,
                capture_output=True, text=True, check=False
            )
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertNotIn("--no-gui", log.read_text())
            env["ROARING_CARLA_GUI"] = "1"
            mode_path.write_text("headless\n")
            run = subprocess.run(
                ["bash", str(script_path), project], env=env,
                capture_output=True, text=True, check=False
            )
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertNotIn("--no-gui", log.read_text())

            duplicate = fake_proc / "987654"
            duplicate.mkdir()
            (duplicate / "cmdline").write_bytes(
                b"/usr/bin/python3\0/app/share/carla/carla\0--with-appname=test\0"
            )
            run = subprocess.run(
                ["bash", str(script_path), project], env=env,
                capture_output=True, text=True, check=False
            )
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn("already running", run.stderr)

    def test_carla_process_scanner_ignores_shell_arguments_with_carla_path(self):
        helper = ROOT / "Bin/roaring_carla_launch.sh"
        shell = r"""set -euo pipefail
source <(sed -n '/^carla_pids() {/,/^}/p' "$HELPER")
carla_pids
"""
        with tempfile.TemporaryDirectory() as temp_dir:
            proc = pathlib.Path(temp_dir) / "proc"
            proc.mkdir()
            genuine = proc / "987654"
            genuine.mkdir()
            (genuine / "cmdline").write_bytes(
                b"/usr/bin/python3\0/app/share/carla/carla\0--no-gui\0"
            )
            wrapper = proc / "987655"
            wrapper.mkdir()
            (wrapper / "cmdline").write_bytes(
                b"/bin/bash\0-lc\0run /usr/bin/python3 /app/share/carla/carla --no-gui\0"
            )
            result = subprocess.run(
                ["bash", "-c", shell],
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "HELPER": str(helper),
                    "ROARING_CARLA_PROC_ROOT": str(proc),
                },
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "987654")

    def test_carla_stale_engine_helper_is_scoped_and_used_by_service(self):
        helper = (ROOT / "Bin/roaring_carla_stop_stale.sh").read_text()
        unit = (ROOT / "User/roaring-carla-session.service").read_text()
        self.assertIn("ancestors_file", helper)
        self.assertIn("ROARING_CARLA_PROC_ROOT", helper)
        self.assertIn("ExecStartPre=%h/bin/roaring_carla_stop_stale.sh", unit)
        self.assertNotIn("pkill -f", unit)
        self.assertNotIn("pgrep -f", unit)

    def test_carla_poststart_preserves_learned_1024_frame_safe_floor(self):
        helper = (ROOT / "Bin/roaring_carla_set_quantum.sh").read_text()
        self.assertIn("mic-safe-quantum", helper)
        self.assertIn("preserving learned Scarlett-safe 1024-frame graph floor", helper)

    def test_carla_service_unit_has_safe_headless_and_scoped_startup(self):
        unit = (ROOT / "User/roaring-carla-session.service").read_text()
        self.assertIn("ExecStartPre=%h/bin/roaring_carla_wait_ready.sh", unit)
        self.assertIn("ExecStartPre=%h/bin/roaring_carla_stop_stale.sh", unit)
        self.assertNotIn("pgrep -f", unit)
        self.assertNotIn("pkill -f", unit)

    def test_carla_quantum_post_start_helper_persists_graph_period(self):
        helper = ROOT / "Bin/roaring_carla_set_quantum.sh"
        source = helper.read_text()
        unit = (ROOT / "User/roaring-carla-session.service").read_text()
        self.assertIn("ROARING_CARLA_QUANTUM", unit)
        self.assertIn("Environment=ROARING_CARLA_QUANTUM=512", unit)
        self.assertIn("ExecStartPost=%h/bin/roaring_carla_set_quantum.sh", unit)
        self.assertIn("clock.force-quantum", source)
        self.assertIn('node.name = "Carla"', source)
        self.assertIn("exit 0", source)

        with tempfile.TemporaryDirectory() as temp_dir:
            fake_bin = pathlib.Path(temp_dir) / "bin"
            fake_bin.mkdir()
            log = pathlib.Path(temp_dir) / "metadata.log"
            pw_cli = fake_bin / "pw-cli"
            pw_cli.write_text("""#!/bin/sh
printf '%s\\n' 'id 251, type PipeWire:Interface:Node/3'
printf '%s\\n' 'node.name = "Carla"'
""")
            pw_cli.chmod(0o755)
            pw_metadata = fake_bin / "pw-metadata"
            pw_metadata.write_text("""#!/bin/sh
printf '%s\\n' "$*" >> "$PW_METADATA_LOG"
case "$*" in
  *clock.force-quantum*) echo "set property" ;;
  *) echo "update: id:0 key:'clock.force-quantum' value:'512' type:''" ;;
esac
""")
            pw_metadata.chmod(0o755)
            result = subprocess.run(
                ["bash", str(helper)],
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "PATH": str(fake_bin) + os.pathsep + os.environ.get("PATH", ""),
                    "PW_METADATA_LOG": str(log),
                },
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("forced PipeWire graph quantum to 512", result.stdout)
            self.assertIn("-n settings 0 clock.force-quantum 512", log.read_text())

            safe_dir = pathlib.Path(temp_dir) / ".config" / "roaring"
            safe_dir.mkdir(parents=True, exist_ok=True)
            (safe_dir / "mic-safe-quantum").write_text("1024\n")
            env = {
                **os.environ,
                "PATH": str(fake_bin) + os.pathsep + os.environ.get("PATH", ""),
                "PW_METADATA_LOG": str(log),
                "HOME": temp_dir,
            }
            result = subprocess.run(
                ["bash", str(helper)], capture_output=True, text=True,
                env=env, check=False
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("preserving learned Scarlett-safe 1024-frame graph floor", result.stdout)
            self.assertIn("-n settings 0 clock.force-quantum 1024", log.read_text())

    def test_carla_wait_ready_helper_replaces_quoted_unit_commands(self):
        helper = (ROOT / "Bin/roaring_carla_wait_ready.sh").read_text()
        unit = (ROOT / "User/roaring-carla-session.service").read_text()
        for sink in ("mic_b1", "mic_b2", "vm_game", "vm_chat", "vm_music"):
            self.assertIn(sink, helper)
        self.assertIn("wait_for_pactl", helper)
        self.assertIn("wait_for_wayland", helper)
        self.assertIn("ExecStartPre=%h/bin/roaring_carla_wait_ready.sh", unit)
        self.assertIn("ExecStartPre=%h/bin/roaring_carla_stop_stale.sh", unit)
        self.assertNotIn("ExecStartPre=/usr/bin/bash -c", unit)

    def test_pipewire_profile_uses_measured_low_latency_default_and_quality(self):
        source = (ROOT / "PipeWire/10-clock-and-resample.conf").read_text()
        self.assertIn("default.clock.quantum       = 512", source)
        self.assertIn("default.clock.min-quantum   = 256", source)
        self.assertIn("default.clock.rate          = 48000", source)
        self.assertIn("resample.quality            = 10", source)

    def test_pipewire_safe_quantum_persistence_is_atomic_and_private(self):
        script_path = ROOT / "Bin/roaring_moonlight_micd.sh"
        shell = r"""set -euo pipefail
SAFE_QUANTUM_FILE="$SAFE_FILE"
source <(sed -n '/^persist_safe_quantum() {/,/^}/p' "$SCRIPT_PATH")
persist_safe_quantum 1024
cat "$SAFE_QUANTUM_FILE"
stat -c '%a' "$SAFE_QUANTUM_FILE"
if persist_safe_quantum 300; then
  echo "invalid value unexpectedly accepted" >&2
  exit 1
fi
"""
        with tempfile.TemporaryDirectory() as temp_dir:
            safe_file = pathlib.Path(temp_dir) / "config" / "mic-safe-quantum"
            result = subprocess.run(
                ["bash", "-c", shell],
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "SCRIPT_PATH": str(script_path),
                    "SAFE_FILE": str(safe_file),
                },
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "1024\n600\n")
            self.assertEqual(safe_file.read_text(), "1024\n")

    def test_pipewire_xrun_monitor_helpers_parse_and_escalate(self):
        script_path = ROOT / "Bin/roaring_moonlight_micd.sh"
        shell = r"""set -euo pipefail
SCRIPT_PATH="$SCRIPT_PATH"
source <(sed -n '/^pipewire_quantum() {/,/^}/p' "$SCRIPT_PATH")
source <(sed -n '/^parse_scarlett_xrun_count() {/,/^}/p' "$SCRIPT_PATH")
source <(sed -n '/^next_pipewire_quantum_after_xrun() {/,/^}/p' "$SCRIPT_PATH")
pw-metadata() {
  printf "update: id:0 key:'clock.quantum' value:'1024' type:''\\n"
  printf "update: id:0 key:'clock.force-quantum' value:'%s' type:''\\n" "$TEST_FORCE"
}
printf 'qforced=%s\\n' "$(pipewire_quantum)"
printf '%s\\n' 'S ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME'
printf '%s\\n' 'R 95 256 48000 195us 1us 0.04 0.00 7 S32LE 2 48000 alsa_input.usb-Focusrite_Scarlett_Solo_USB_test'
printf 'xrun=%s\\n' "$(parse_scarlett_xrun_count < "$FIXTURE")"
printf 'fallback256=%s\\n' "$(next_pipewire_quantum_after_xrun 256)"
printf 'fallback512=%s\\n' "$(next_pipewire_quantum_after_xrun 512)"
printf 'fallback1024=%s\\n' "$(next_pipewire_quantum_after_xrun 1024)"
"""
        for forced, expected_quantum in (("0", "1024"), ("256", "256"), ("512", "512")):
            with self.subTest(forced=forced):
                with tempfile.TemporaryDirectory() as temp_dir:
                    fixture = pathlib.Path(temp_dir) / "pw-top.txt"
                    fixture.write_text(
                        "R 95 256 48000 195us 1us 0.04 0.00 7 S32LE 2 48000 "
                        "alsa_input.usb-Focusrite_Scarlett_Solo_USB_test\\n"
                    )
                    env = os.environ.copy()
                    env.update({
                        "SCRIPT_PATH": str(script_path),
                        "TEST_FORCE": forced,
                        "FIXTURE": str(fixture),
                    })
                    result = subprocess.run(
                        ["bash", "-c", shell],
                        capture_output=True,
                        text=True,
                        env=env,
                        check=False,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(f"qforced={expected_quantum}", result.stdout)
                    self.assertIn("xrun=7", result.stdout)
                    self.assertIn("fallback256=512", result.stdout)
                    self.assertIn("fallback512=1024", result.stdout)
                    self.assertIn("fallback1024=0", result.stdout)

    def test_pipewire_stable_quantum_recovery_respects_configured_floor(self):
        script_path = ROOT / "Bin/roaring_moonlight_micd.sh"
        shell = r"""set -euo pipefail
source <(sed -n '/^lower_pipewire_quantum_after_stability() {/,/^}/p' "$SCRIPT_PATH")
printf '%s ' "$(lower_pipewire_quantum_after_stability 1024 512)"
printf '%s ' "$(lower_pipewire_quantum_after_stability 512 512)"
printf '%s ' "$(lower_pipewire_quantum_after_stability 512 256)"
printf '%s ' "$(lower_pipewire_quantum_after_stability 1024 256)"
printf '%s ' "$(lower_pipewire_quantum_after_stability 256 256)"
printf '%s' "$(lower_pipewire_quantum_after_stability 1024 1024)"
"""
        result = subprocess.run(
            ["bash", "-c", shell],
            capture_output=True,
            text=True,
            env={**os.environ, "SCRIPT_PATH": str(script_path)},
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "512 0 256 512 0 0")

    def test_pipewire_xrun_monitor_retries_until_active_node_appears(self):
        script_path = ROOT / "Bin/roaring_moonlight_micd.sh"
        shell = r"""set -euo pipefail
source <(sed -n '/^wait_for_scarlett_xrun_baseline() {/,/^}/p' "$SCRIPT_PATH")
scarlett_xrun_count() {
  n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" > "$COUNT_FILE"
  if (( n < 3 )); then return 1; fi
  echo 7
}
kill() { return 0; }
sleep() { :; }
baseline="$(wait_for_scarlett_xrun_baseline synthetic-pid)"
n=$(cat "$COUNT_FILE")
printf '%s %s' "$baseline" "$n"
"""
        with tempfile.TemporaryDirectory() as temp_dir:
            counter = pathlib.Path(temp_dir) / "attempts"
            result = subprocess.run(
                ["bash", "-c", shell],
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "SCRIPT_PATH": str(ROOT / "Bin/roaring_moonlight_micd.sh"),
                    "COUNT_FILE": str(counter),
                },
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "7 3")

    def test_pipewire_xrun_parser_ignores_inactive_scarlett_rows(self):
        script_path = ROOT / "Bin/roaring_moonlight_micd.sh"
        shell = r"""set -euo pipefail
source <(sed -n '/^parse_scarlett_xrun_count() {/,/^}/p' "$SCRIPT_PATH")
if echo 'R 95 0 0 0.0us 0.0us ??? ??? 0 S32LE 2 48000 alsa_input.usb-Focusrite_Scarlett_Solo_USB_test' | parse_scarlett_xrun_count; then
  exit 9
fi
echo 'R 95 512 48000 600us 1us 0.06 0.00 3 S32LE 2 48000 alsa_input.usb-Focusrite_Scarlett_Solo_USB_test' | parse_scarlett_xrun_count
"""
        result = subprocess.run(
            ["bash", "-c", shell],
            capture_output=True,
            text=True,
            env={**os.environ, "SCRIPT_PATH": str(script_path)},
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "3")

    def test_sender_requests_mono_low_latency_capture_and_bounds_glitch_fallback(self):
        source = (ROOT / "Bin/roaring_moonlight_micd.sh").read_text()
        self.assertIn("-filter_threads 1", source)
        self.assertIn("-sample_rate \"$RATE\"", source)
        self.assertIn("-channels \"$CHANNELS\"", source)
        self.assertIn("-fragment_size \"$PULSE_FRAGMENT_BYTES\"", source)
        self.assertIn("-fflags +nobuffer", source)
        self.assertIn("PULSE_FRAGMENT_MAX=1920", source)
        self.assertIn("PULSE_FRAGMENT_FALLBACK=1", source)
        self.assertIn("ran >= 600", source)


if __name__ == "__main__":
    unittest.main()
