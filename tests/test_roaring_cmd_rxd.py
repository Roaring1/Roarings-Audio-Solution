import contextlib
import importlib.util
import io
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "Bin" / "roaring_cmd_rxd.py"
SPEC = importlib.util.spec_from_file_location("roaring_cmd_rxd", MODULE_PATH)
receiver = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(receiver)


class FakeSocket:
    def __init__(self):
        self.sent = []

    def sendto(self, payload, address):
        self.sent.append((payload.decode("utf-8"), address))


class CommandReceiverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        receiver.MICCONF = self.root / ".config/hearth/roaring_mic_router.conf"
        receiver.MICCONF.parent.mkdir(parents=True)
        receiver.STATE = self.root / ".config/roaring/mic_source"
        receiver.STATE.parent.mkdir(parents=True)
        receiver.STATE.write_text("b1_mic\n")
        receiver.MICCONF.write_text(
            "# retained comment\n"
            'B1_ROUTE="none"\n'
            'B2_ROUTE="astro"\n'
            'CARLA_TO_B1="true"\n'
            'CARLA_TO_B2="false"\n'
            'B1_ACTIVE="true"\n'
            'UNRELATED="preserve-me"\n'
        )
        self.sock = FakeSocket()
        self.peer = ("192.168.50.132", 54000)

    def tearDown(self):
        self.temp.cleanup()

    def handle(self, command):
        with contextlib.redirect_stdout(io.StringIO()):
            receiver.handle(command, self.peer, self.sock)
        return self.sock.sent[-1][0]

    def completed(self, stdout="", returncode=0, stderr=""):
        return subprocess.CompletedProcess([], returncode, stdout, stderr)

    def test_requested_input_uses_carla_precedence(self):
        self.assertEqual(receiver.requested_mic(), "SM7B")
        receiver._write_conf({"CARLA_TO_B1": "false", "B1_ROUTE": "astro"})
        self.assertEqual(receiver.requested_mic(), "A50 boom")
        receiver._write_conf({"B1_ROUTE": "none"})
        self.assertEqual(receiver.requested_mic(), "none")

    def test_atomic_config_update_preserves_comments_and_unknown_keys(self):
        receiver._write_conf({"CARLA_TO_B1": "false", "B1_ROUTE": "astro"})
        updated = receiver.MICCONF.read_text()
        self.assertIn("# retained comment", updated)
        self.assertIn('UNRELATED="preserve-me"', updated)
        self.assertIn('CARLA_TO_B1="false"', updated)
        self.assertIn('B1_ROUTE="astro"', updated)
        self.assertIn('B2_ROUTE="astro"', updated)
        self.assertFalse(receiver.MICCONF.with_suffix(".conf.tmp").exists())

    def test_applied_sm7b_requires_all_four_live_graph_edges(self):
        graph = (
            "sm7b_mono:capture_MONO\n"
            "  |-> Carla:audio-in1\n"
            "  |-> Carla:audio-in2\n"
            "Carla:audio-out1\n"
            "  |-> mic_b1:playback_FL\n"
            "Carla:audio-out2\n"
            "  |-> mic_b1:playback_FR\n"
        )
        with mock.patch.object(receiver.subprocess, "run", return_value=self.completed(graph)) as run:
            self.assertEqual(receiver.applied_mic(), "SM7B")
            run.assert_called_once()
            self.assertEqual(run.call_args.args[0], ["pw-link", "-l"])

    def test_applied_sm7b_rejects_partial_graph(self):
        graph = (
            "sm7b_mono:capture_MONO\n"
            "  |-> Carla:audio-in1\n"
            "Carla:audio-out1\n"
            "  |-> mic_b1:playback_FL\n"
            "Carla:audio-out2\n"
            "  |-> mic_b1:playback_FR\n"
        )
        with mock.patch.object(receiver.subprocess, "run", return_value=self.completed(graph)):
            self.assertIsNone(receiver.applied_mic())

    def test_applied_astro_requires_matching_loopback(self):
        receiver._write_conf({"CARLA_TO_B1": "false", "B1_ROUTE": "astro"})
        modules = "31\tmodule-loopback\tsource=astro_mic_48k sink=mic_b1\n"
        with mock.patch.object(receiver.subprocess, "run", return_value=self.completed(modules)):
            self.assertEqual(receiver.applied_mic(), "A50 boom")
        with mock.patch.object(receiver.subprocess, "run", return_value=self.completed("32\tmodule-loopback\tsource=other sink=mic_b1\n")):
            self.assertIsNone(receiver.applied_mic())

    def test_disabled_b1_is_neither_requested_nor_reported_applied(self):
        receiver._write_conf({"B1_ACTIVE": "false"})
        self.assertEqual(receiver.requested_mic(), "none")
        with mock.patch.object(receiver.subprocess, "run") as run:
            self.assertIsNone(receiver.applied_mic())
            run.assert_not_called()

    def test_direct_sm7b_route_requires_its_loopback(self):
        receiver._write_conf({"CARLA_TO_B1": "false", "B1_ROUTE": "sm7b"})
        modules = "31\tmodule-loopback\tsource=sm7b_mono sink=mic_b1\n"
        with mock.patch.object(receiver.subprocess, "run", return_value=self.completed(modules)):
            self.assertEqual(receiver.requested_mic(), "SM7B")
            self.assertEqual(receiver.applied_mic(), "SM7B")

    def test_both_direct_routes_require_both_loopbacks(self):
        receiver._write_conf({"CARLA_TO_B1": "false", "B1_ROUTE": "both"})
        modules = (
            "31\tmodule-loopback\tsource=sm7b_mono sink=mic_b1\n"
            "32\tmodule-loopback\tsource=astro_mic_48k sink=mic_b1\n"
        )
        with mock.patch.object(receiver.subprocess, "run", return_value=self.completed(modules)):
            self.assertEqual(receiver.requested_mic(), "SM7B + A50 boom")
            self.assertEqual(receiver.applied_mic(), "SM7B + A50 boom")
        with mock.patch.object(receiver.subprocess, "run", return_value=self.completed(modules.splitlines()[0] + "\n")):
            self.assertIsNone(receiver.applied_mic())

    def test_explicit_set_mic_is_idempotent_and_reports_accepted(self):
        reply = self.handle("set-mic:a50 boom")
        self.assertEqual(reply, "accepted:mic=A50 boom")
        conf = receiver._read_conf()
        self.assertEqual(conf["CARLA_TO_B1"], "false")
        self.assertEqual(conf["B1_ROUTE"], "astro")
        self.assertEqual(conf["B1_ACTIVE"], "true")
        with mock.patch.object(receiver, "set_mic") as set_mic:
            self.assertEqual(self.handle("set-mic:a50 boom"), "accepted:mic=A50 boom")
            set_mic.assert_not_called()

    def test_invalid_set_mic_target_is_rejected(self):
        self.assertEqual(self.handle("set-mic:unknown"), "err:set-mic:target")

    def test_laptop_ip_allowlist_rejects_other_peers(self):
        self.assertTrue(receiver.allowed_peer(("192.168.50.132", 54000)))
        self.assertFalse(receiver.allowed_peer(("192.168.50.124", 54000)))
        self.assertFalse(receiver.allowed_peer(None))

    def test_legacy_b2_source_file_cannot_redirect_b1_mute_controls(self):
        legacy_state = self.root / ".config/roaring/mic_source"
        legacy_state.parent.mkdir(parents=True, exist_ok=True)
        legacy_state.write_text("b2_mic\n")
        self.assertEqual(receiver.current_source(), "b1_mic")

    def test_intentionally_unrouted_bus_is_confirmed_not_pending(self):
        receiver._write_conf({"B1_ACTIVE": "false"})
        with mock.patch.object(receiver, "applied_mic", return_value=None), mock.patch.object(
            receiver.subprocess, "run", return_value=self.completed("Mute: no\n")
        ):
            self.assertEqual(self.handle("status"), "ok:mic=none:muted=no")

    def test_legacy_swap_changes_input_not_sender_bus(self):
        self.assertEqual(self.handle("swap"), "accepted:mic=A50 boom")
        conf = receiver._read_conf()
        self.assertEqual(conf["B1_ROUTE"], "astro")
        self.assertEqual(conf["CARLA_TO_B1"], "false")

    def test_mute_ack_requires_verified_state(self):
        with mock.patch.object(
            receiver.subprocess, "run",
            side_effect=[self.completed(), self.completed("Mute: yes\n")],
        ):
            self.assertEqual(self.handle("mute"), "ok:mute:source=b1_mic")

    def test_mute_does_not_claim_success_when_verification_disagrees(self):
        with mock.patch.object(
            receiver.subprocess, "run",
            side_effect=[self.completed(), self.completed("Mute: no\n")],
        ):
            self.assertEqual(self.handle("mute"), "err:mute:verify")

    def test_mute_command_failure_is_reported(self):
        with mock.patch.object(receiver.subprocess, "run", return_value=self.completed(returncode=1, stderr="not found")):
            self.assertEqual(self.handle("unmute"), "err:unmute:pactl")

    def test_status_reports_applied_route_and_observed_mute_state(self):
        with mock.patch.object(receiver, "applied_mic", return_value="SM7B"), mock.patch.object(
            receiver.subprocess, "run", return_value=self.completed("Mute: no\n")
        ):
            self.assertEqual(self.handle("status"), "ok:mic=SM7B:muted=no")

    def test_status_does_not_claim_route_applied_when_graph_is_missing(self):
        with mock.patch.object(receiver, "applied_mic", return_value=None), mock.patch.object(
            receiver.subprocess, "run", return_value=self.completed("Mute: no\n")
        ):
            self.assertEqual(self.handle("status"), "pending:mic=SM7B:muted=no")

    def test_unknown_command_is_rejected(self):
        self.assertEqual(self.handle("not-a-command"), "err:unknown")


if __name__ == "__main__":
    unittest.main()
