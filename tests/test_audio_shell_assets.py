import pathlib
import subprocess
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
        self.assertIn('[[ "${B1_ACTIVE:-true}" == "true" ]] || want_b1=false', source)
        self.assertIn('[[ "${B2_ACTIVE:-true}" == "true" ]] || want_b2=false', source)

    def test_sender_defaults_to_b1_and_uses_private_fifo_directory(self):
        source = (ROOT / "Bin/roaring_moonlight_micd.sh").read_text()
        self.assertIn('MIC_SOURCE="${MIC_SOURCE:-b1_mic}"', source)
        self.assertIn('mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/moonlight-micd.XXXXXX"', source)
        self.assertNotIn("$(mktemp -u", source)
        self.assertNotIn("fifo=$(mktemp -u", source)
        self.assertIn("wait_for_peer", source)
        self.assertIn("GLITCH_LIMIT", source)


if __name__ == "__main__":
    unittest.main()
