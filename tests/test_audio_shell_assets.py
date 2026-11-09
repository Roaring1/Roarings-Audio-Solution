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


if __name__ == "__main__":
    unittest.main()
