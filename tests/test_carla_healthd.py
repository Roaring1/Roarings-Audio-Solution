import math
import os
import pathlib
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Bin"))

import roaring_carla_healthd as health


def speech_like(seconds=0.1, rate=48000):
    out = []
    count = int(seconds * rate)
    for i in range(count):
        t = i / rate
        envelope = 0.45 + 0.35 * math.sin(2 * math.pi * 2.3 * t)
        sample = envelope * (
            0.16 * math.sin(2 * math.pi * 145 * t)
            + 0.07 * math.sin(2 * math.pi * 310 * t)
            + 0.025 * math.sin(2 * math.pi * 1150 * t)
        )
        out.append(sample)
    return out


class CarlaQualityAnalysisTests(unittest.TestCase):
    def test_identical_clean_signal_has_no_candidate(self):
        raw = speech_like()
        result = health.analyze_pair(raw, raw)
        self.assertTrue(result["valid"])
        self.assertFalse(result["candidate"])
        self.assertFalse(result["dropout"])

    def test_linear_gain_and_frequency_shaping_have_no_candidate(self):
        raw = speech_like()
        processed = []
        previous = 0.0
        for sample in raw:
            previous = 0.35 * sample + 0.65 * previous
            processed.append(previous * 1.4)
        result = health.analyze_pair(raw, processed)
        self.assertTrue(result["valid"])
        self.assertFalse(result["candidate"])

    def test_alignment_recovers_carla_delay_and_keeps_clean_signal_valid(self):
        raw = speech_like()
        delay = 225
        processed = [0.0] * delay + [sample * 1.25 for sample in raw[:-delay]]
        lag, correlation = health._best_alignment(raw, processed)
        self.assertAlmostEqual(lag, delay, delta=16)
        self.assertGreater(correlation, 0.95)
        result = health.analyze_pair(raw, processed)
        self.assertTrue(result["valid"])
        self.assertFalse(result["candidate"])

    def test_measured_level_clean_speech_remains_valid(self):
        raw = [sample * 0.01 for sample in speech_like()]
        processed = [sample * 8.0 for sample in raw]
        result = health.analyze_pair(raw, processed)
        self.assertTrue(result["valid"])
        self.assertFalse(result["candidate"])

    def test_measured_level_dropout_requires_sustained_loud_input(self):
        raw = [sample * 0.02 for sample in speech_like()]
        with patch.object(health, "_b1_expected_active", return_value=True):
            result = health.analyze_pair(raw, [0.0] * len(raw))
        self.assertTrue(result["dropout"])

    def test_measured_level_output_only_click_is_detected(self):
        raw = [sample * 0.01 for sample in speech_like()]
        processed = [sample * 8.0 for sample in raw]
        for index in range(2100, 2124):
            processed[index] += 0.08
        result = health.analyze_pair(raw, processed)
        self.assertTrue(result["valid"])
        self.assertTrue(result["candidate"])

    def test_raw_speech_transient_does_not_look_like_output_only_crackle(self):
        raw = speech_like()
        for index in range(2100, 2124):
            raw[index] += 0.18
        processed = [sample * 1.25 for sample in raw]
        result = health.analyze_pair(raw, processed)
        self.assertFalse(result["candidate"])

    def test_raw_and_processed_sibilant_burst_is_not_a_crackle_candidate(self):
        raw = speech_like()
        for index in range(1200, 1600):
            raw[index] += 0.035 * math.sin(2 * math.pi * 6200 * index / 48000)
        processed = [sample * 1.25 for sample in raw]
        result = health.analyze_pair(raw, processed)
        self.assertFalse(result["candidate"])

    def test_output_only_click_is_detected_as_candidate(self):
        raw = speech_like()
        processed = [sample * 1.25 for sample in raw]
        for index in range(2100, 2124):
            processed[index] += 0.30
        result = health.analyze_pair(raw, processed)
        self.assertTrue(result["valid"])
        self.assertTrue(result["candidate"])

    def test_loud_raw_signal_with_silent_processed_signal_is_a_dropout(self):
        from unittest.mock import patch
        raw = speech_like()
        with patch.object(health, "_b1_expected_active", return_value=True):
            result = health.analyze_pair(raw, [0.0] * len(raw))
        self.assertTrue(result["dropout"])

    def test_intentionally_muted_b1_is_not_classified_as_a_dropout(self):
        from unittest.mock import patch
        raw = speech_like()
        with patch.object(health, "_b1_expected_active", return_value=False):
            result = health.analyze_pair(raw, [0.0] * len(raw))
        self.assertFalse(result["dropout"])

    def test_silence_never_triggers_a_transient(self):
        result = health.analyze_pair([0.0] * 4800, [0.0] * 4800)
        self.assertFalse(result["candidate"])
        self.assertFalse(result["dropout"])

    def test_three_output_only_events_within_window_confirm_fault(self):
        tracker = health.QualityTracker()
        candidate = {"candidate": True, "dropout": False}
        self.assertFalse(tracker.observe(candidate, 1.0))
        self.assertFalse(tracker.observe(candidate, 2.0))
        self.assertTrue(tracker.observe(candidate, 3.0))
        self.assertFalse(tracker.observe(candidate, 3.1))

    def test_single_transient_does_not_confirm_fault(self):
        tracker = health.QualityTracker()
        self.assertFalse(tracker.observe({"candidate": True}, 1.0))

    def test_transient_events_expire_from_rolling_window(self):
        tracker = health.QualityTracker()
        tracker.observe({"candidate": True}, 1.0)
        tracker.observe({"candidate": True}, 1.5)
        self.assertFalse(tracker.observe({"candidate": True}, 8.0))

    def test_three_consecutive_loud_input_dropouts_confirm_fault(self):
        tracker = health.QualityTracker()
        dropout = {"candidate": False, "dropout": True}
        self.assertFalse(tracker.observe(dropout, 1.0))
        self.assertFalse(tracker.observe(dropout, 1.1))
        self.assertTrue(tracker.observe(dropout, 1.2))


class CarlaIntermittentCycleTests(unittest.TestCase):
    def test_confirmed_fault_restarts_once_and_verifies_once(self):
        incorrect = {
            "verdict": "INCORRECT", "reason": "confirmed fault", "windows": 80,
            "active_windows": 40, "valid_windows": 20, "candidate_windows": 3,
            "dropout_windows": 0, "raw_rms_p50": 0.001, "raw_rms_p90": 0.002,
            "post_rms_p50": 0.008, "post_rms_p90": 0.01, "correlation_p50": 0.7,
        }
        correct = {
            "verdict": "CORRECT", "reason": "clean", "windows": 80,
            "active_windows": 40, "valid_windows": 38, "candidate_windows": 0,
            "dropout_windows": 0, "raw_rms_p50": 0.001, "raw_rms_p90": 0.002,
            "post_rms_p50": 0.008, "post_rms_p90": 0.01, "correlation_p50": 0.8,
        }
        stored = {}
        with patch.object(health, "_b1_expected_active", return_value=True), \
             patch.object(health, "capture_sample", side_effect=[incorrect, correct]) as sample, \
             patch.object(health, "_read_state", side_effect=[{}, {}]), \
             patch.object(health, "handle_confirmed_fault", return_value=(True, "Carla restarted")) as restart, \
             patch.object(health, "_write_state", side_effect=lambda value: stored.update(value)), \
             patch.object(health, "_record_sample"), patch.object(health, "notify"):
            code = health.run_sample_cycle(8.0, {"AUTO_RECOVER": True, "NOTIFY": True})
        self.assertEqual(code, 0)
        self.assertEqual(sample.call_count, 2)
        restart.assert_called_once()
        self.assertEqual(stored["last_verdict"], "RECOVERED")
        self.assertEqual(stored["last_recheck"]["verdict"], "CORRECT")

    def test_no_sample_never_restarts_carla(self):
        no_sample = {
            "verdict": "NO_SAMPLE", "reason": "quiet", "windows": 80,
            "active_windows": 0, "valid_windows": 0, "candidate_windows": 0,
            "dropout_windows": 0, "raw_rms_p50": 0.00005, "raw_rms_p90": 0.0001,
            "post_rms_p50": 0.001, "post_rms_p90": 0.0012, "correlation_p50": 0.7,
        }
        stored = {}
        with patch.object(health, "_b1_expected_active", return_value=True), \
             patch.object(health, "capture_sample", return_value=no_sample), \
             patch.object(health, "_read_state", return_value={}), \
             patch.object(health, "handle_confirmed_fault") as restart, \
             patch.object(health, "_write_state", side_effect=lambda value: stored.update(value)), \
             patch.object(health, "_record_sample"):
            code = health.run_sample_cycle(8.0, {"AUTO_RECOVER": True, "NOTIFY": True})
        self.assertEqual(code, 0)
        restart.assert_not_called()
        self.assertEqual(stored["last_verdict"], "NO_SAMPLE")


class CarlaIntermittentVerdictTests(unittest.TestCase):
    def test_quiet_sample_is_no_sample_and_never_a_fault(self):
        verdict, _ = health.classify_sample({
            "fault_confirmed": False, "active_windows": 0, "valid_windows": 0,
            "candidate_windows": 0, "dropout_windows": 0,
        })
        self.assertEqual(verdict, "NO_SAMPLE")

    def test_clean_active_correlated_sample_is_correct(self):
        verdict, _ = health.classify_sample({
            "fault_confirmed": False, "active_windows": 10, "valid_windows": 9,
            "candidate_windows": 0, "dropout_windows": 0,
        })
        self.assertEqual(verdict, "CORRECT")

    def test_isolated_candidate_is_suspect_not_a_restart_fault(self):
        verdict, _ = health.classify_sample({
            "fault_confirmed": False, "active_windows": 10, "valid_windows": 10,
            "candidate_windows": 1, "dropout_windows": 0,
        })
        self.assertEqual(verdict, "SUSPECT")

    def test_only_confirmed_repeated_fault_is_incorrect(self):
        verdict, _ = health.classify_sample({
            "fault_confirmed": True, "active_windows": 10, "valid_windows": 4,
            "candidate_windows": 3, "dropout_windows": 0,
        })
        self.assertEqual(verdict, "INCORRECT")

    def test_raw_activity_floor_matches_measured_source_scale(self):
        self.assertAlmostEqual(health.RAW_ACTIVITY_RMS_FLOOR, 0.00025)
        self.assertLess(health.RAW_ACTIVITY_RMS_FLOOR, 0.001153)


class CarlaHealthSafetyTests(unittest.TestCase):
    def test_auto_recover_is_off_by_default(self):
        self.assertFalse(health.load_config(pathlib.Path("/does/not/exist"))["AUTO_RECOVER"])

    def test_link_parser_accepts_pw_link_outgoing_and_incoming_forms(self):
        graph = (
            "Carla:audio-out1\n  |-> mic_b1:playback_FL\n"
            "mic_b1:playback_FR\n  |<- Carla:audio-out2\n"
        )
        self.assertTrue(health._link_present(graph, "Carla:audio-out1", "mic_b1:playback_FL"))
        self.assertTrue(health._link_present(graph, "Carla:audio-out2", "mic_b1:playback_FR"))
        self.assertFalse(health._link_present(graph, "Carla:audio-out1", "mic_b1:playback_FR"))

    def test_restart_circuit_breaker_rejects_too_many_restarts(self):
        now = 100000.0
        state = {"restart_times": [now - 100, now - 50], "last_restart": now - 1000}
        allowed, reason = health._restart_allowed(state, now)
        self.assertFalse(allowed)
        self.assertIn("circuit breaker", reason)

    def test_restart_cooldown_rejects_early_retry(self):
        now = 100000.0
        state = {"restart_times": [now - 100], "last_restart": now - 20}
        allowed, reason = health._restart_allowed(state, now)
        self.assertFalse(allowed)
        self.assertIn("cooldown", reason)

    def test_state_write_is_private_and_round_trips(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temp_dir:
            path = pathlib.Path(temp_dir) / "state.json"
            health._write_state({"last_restart": 12.5, "restart_times": [12.5]}, path)
            self.assertEqual(health._read_state(path)["last_restart"], 12.5)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)




class CarlaPatchWatcherTests(unittest.TestCase):
    def _probe_watcher_link(self, graph, *, pipewire_query_ok=True, graph_query_ok=True):
        script_path = ROOT / "Bin/roaring_carla_watchd.sh"
        shell = r"""set -euo pipefail
source <(sed -n '/^has_link() {/,/^}/p' "$WATCHER")
pw-link() {
  if [[ "$1" == "-l" ]]; then
    [[ "$GRAPH_QUERY_OK" == "1" ]] || return 5
    printf '%s' "$GRAPH"
    return 0
  fi
}
pw-cli() { [[ "$PIPEWIRE_QUERY_OK" == "1" ]]; }
rc=0
has_link Carla audio-out1 mic_b1 playback_FL || rc=$?
printf '%s' "$rc"
"""
        result = subprocess.run(
            ["bash", "-c", shell],
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "WATCHER": str(script_path),
                "GRAPH": graph,
                "PIPEWIRE_QUERY_OK": "1" if pipewire_query_ok else "0",
                "GRAPH_QUERY_OK": "1" if graph_query_ok else "0",
            },
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_pw_link_watcher_recognizes_outgoing_connection(self):
        graph = "Carla:audio-out1\n  |-> mic_b1:playback_FL\n"
        self.assertEqual(self._probe_watcher_link(graph), "0")

    def test_pw_link_watcher_recognizes_incoming_connection(self):
        graph = "mic_b1:playback_FL\n  |<- Carla:audio-out1\n"
        self.assertEqual(self._probe_watcher_link(graph), "0")

    def test_successful_empty_graph_means_link_absent_and_repairable(self):
        self.assertEqual(self._probe_watcher_link(""), "1")

    def test_empty_graph_with_pipewire_unavailable_fails_closed(self):
        self.assertEqual(self._probe_watcher_link("", pipewire_query_ok=False), "3")

    def test_pw_link_command_error_fails_closed(self):
        self.assertEqual(self._probe_watcher_link("", graph_query_ok=False), "3")

    def test_watchdog_no_longer_depends_on_pw_dump_json(self):
        source = (ROOT / "Bin/roaring_carla_watchd.sh").read_text()
        self.assertIn("pw-link -l", source)
        self.assertNotIn("pw-dump", source)


class CarlaProcessOwnershipTests(unittest.TestCase):
    def _make_proc(self, root, pid, argv):
        process = pathlib.Path(root) / str(pid)
        process.mkdir()
        (process / "cmdline").write_bytes(b"\0".join(arg.encode() for arg in argv) + b"\0")
        (process / "cgroup").write_text("0::/user.slice/test.scope\n")
        return process

    def test_exact_carla_backend_is_found(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temp_dir:
            self._make_proc(temp_dir, 111, ["/usr/bin/python3", "/app/share/carla/carla", "--no-gui"])
            self._make_proc(temp_dir, 112, ["/bin/bash", "-lc", "/app/share/carla/carla"])
            processes = health._carla_processes(pathlib.Path(temp_dir))
            self.assertEqual([entry[0] for entry in processes], [111])

    def test_unknown_launcher_and_multiple_instances_fail_safe(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temp_dir:
            self._make_proc(temp_dir, 111, ["/usr/bin/python3", "/app/share/carla/carla", "--no-gui"])
            self._make_proc(temp_dir, 112, ["/usr/bin/python3", "/app/share/carla/carla", "--no-gui"])
            processes = health._carla_processes(pathlib.Path(temp_dir))
            self.assertEqual(len(processes), 2)

    def test_ui_editing_instance_is_not_headless(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temp_dir:
            self._make_proc(temp_dir, 111, ["/usr/bin/python3", "/app/share/carla/carla", "/tmp/project.carxp"])
            processes = health._carla_processes(pathlib.Path(temp_dir))
            self.assertEqual(len(processes), 1)
            self.assertNotIn("--no-gui", processes[0][1])


class PipeWireTelemetryTests(unittest.TestCase):
    def test_parse_pw_top_extracts_scarlett_carla_and_b1_errors(self):
        fixture = """S ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
R 95 512 48000 600us 15us 0.06 0.00 14 S32LE 2 48000 alsa_input.usb-Focusrite_Scarlett_Solo_USB_test
R 251 512 48000 300us 50us 0.02 0.01 0 F32LE 2 48000 Carla
R 261 512 48000 250us 20us 0.02 0.00 2 F32LE 2 48000 b1_mic
"""
        parsed = health.parse_pw_top(fixture)
        self.assertEqual(parsed["scarlett"]["errors"], 14)
        self.assertEqual(parsed["carla"]["errors"], 0)
        self.assertEqual(parsed["b1"]["errors"], 2)
        self.assertEqual(parsed["scarlett"]["quantum"], 512)

    def test_parse_pw_top_keeps_maximum_active_counter_not_later_zero_row(self):
        fixture = """S ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
R 95 512 48000 600us 15us 0.06 0.00 14 S32LE 2 48000 alsa_input.usb-Focusrite_Scarlett_Solo_USB_test
S 95 0 0 --- --- --- --- 0 S32LE 2 48000 alsa_input.usb-Focusrite_Scarlett_Solo_USB_test
"""
        parsed = health.parse_pw_top(fixture)
        self.assertEqual(parsed["scarlett"]["errors"], 14)
        self.assertEqual(parsed["scarlett"]["quantum"], 512)
        self.assertEqual(parsed["scarlett"]["rate"], 48000)
        self.assertEqual(parsed["scarlett"]["status"], "R")

    def test_parse_pw_top_ignores_headers_and_non_numeric_rows(self):
        fixture = """S ID QUANT RATE WAIT BUSY W/Q B/Q ERR FORMAT NAME
R 95 --- 48000 --- --- --- --- --- S32LE alsa_input.usb-Focusrite_Scarlett_Solo_USB_test
"""
        self.assertEqual(health.parse_pw_top(fixture), {})

    def test_new_pipewire_errors_notify_once_with_node_identity(self):
        from unittest.mock import patch
        state = {"pwtop_counters": {"scarlett": 14, "carla": 0}}
        snapshot = {"quantum": 512, "rate": 48000, "nodes": {
            "scarlett": {"errors": 15, "status": "R"},
            "carla": {"errors": 0, "status": "R"},
        }}
        with patch.object(health, "notify") as notify:
            last = health._report_runtime_deltas(
                snapshot, state, notify_enabled=True, now=1000.0, last_notification=0.0
            )
        notify.assert_called_once()
        self.assertIn("scarlett ERR 14->15", notify.call_args.args[1])
        self.assertEqual(last, 1000.0)
        self.assertEqual(state["pwtop_counters"]["scarlett"], 15)

    def test_pipewire_counter_baseline_does_not_notify(self):
        from unittest.mock import patch
        state = {}
        snapshot = {"quantum": 512, "rate": 48000, "nodes": {
            "scarlett": {"errors": 14, "status": "R"},
        }}
        with patch.object(health, "notify") as notify:
            health._report_runtime_deltas(
                snapshot, state, notify_enabled=True, now=1000.0, last_notification=0.0
            )
        notify.assert_not_called()
        self.assertEqual(state["pwtop_counters"]["scarlett"], 14)

    def test_pipewire_counter_reset_rebaselines_without_false_alert(self):
        from unittest.mock import patch
        state = {"pwtop_counters": {"scarlett": 14}}
        snapshot = {"nodes": {"scarlett": {"errors": 0, "status": "R"}}}
        with patch.object(health, "notify") as notify:
            health._report_runtime_deltas(
                snapshot, state, notify_enabled=True, now=1000.0, last_notification=0.0
            )
        notify.assert_not_called()
        self.assertEqual(state["pwtop_counters"]["scarlett"], 0)



class CarlaRecoveryAttemptTests(unittest.TestCase):
    def test_failed_restart_is_counted_and_cannot_retry_during_cooldown(self):
        import tempfile
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temp_dir:
            state_path = pathlib.Path(temp_dir) / "state.json"
            state = {}
            with patch.object(health, "STATE_PATH", state_path), \
                 patch.object(health, "restart_carla_safely", return_value=(False, "test failure")) as restart:
                ok, detail = health.handle_confirmed_fault({"AUTO_RECOVER": True}, state)
                self.assertFalse(ok)
                self.assertEqual(detail, "test failure")
                self.assertEqual(len(state["restart_times"]), 1)
                again, reason = health.handle_confirmed_fault({"AUTO_RECOVER": True}, state)
                self.assertFalse(again)
                self.assertIn("cooldown", reason)
                restart.assert_called_once()
                self.assertEqual(len(health._read_state(state_path)["restart_times"]), 1)


class B1ExpectedStateTests(unittest.TestCase):
    def test_active_unmuted_b1_is_eligible_for_quality_comparison(self):
        import tempfile
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temp_dir:
            router_config = pathlib.Path(temp_dir) / "roaring_mic_router.conf"
            router_config.write_text('B1_ACTIVE="true"\nCARLA_TO_B1="true"\n')
            with patch.object(health, "ROUTER_CONFIG_PATH", router_config), \
                 patch.object(health, "_run_checked") as run:
                run.return_value.returncode = 0
                run.return_value.stdout = "Mute: no\n"
                health._B1_ACTIVE_CACHE = (0.0, False)
                self.assertTrue(health._b1_expected_active())
                self.assertEqual(run.call_count, 2)

    def test_muted_or_disabled_b1_is_not_eligible_for_dropout_detection(self):
        import tempfile
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temp_dir:
            router_config = pathlib.Path(temp_dir) / "roaring_mic_router.conf"
            router_config.write_text('B1_ACTIVE="true"\nCARLA_TO_B1="false"\n')
            with patch.object(health, "ROUTER_CONFIG_PATH", router_config), \
                 patch.object(health, "_run_checked") as run:
                health._B1_ACTIVE_CACHE = (0.0, True)
                self.assertFalse(health._b1_expected_active())
                run.assert_not_called()


    def test_muted_b1_sink_skips_quality_sampling(self):
        import tempfile
        from unittest.mock import patch
        from subprocess import CompletedProcess
        with tempfile.TemporaryDirectory() as temp_dir:
            router_config = pathlib.Path(temp_dir) / "roaring_mic_router.conf"
            router_config.write_text('B1_ACTIVE="true"\nCARLA_TO_B1="true"\n')
            with patch.object(health, "ROUTER_CONFIG_PATH", router_config), \
                 patch.object(health, "_run_checked", return_value=CompletedProcess([], 0, stdout="Mute: yes\n", stderr="")) as run:
                health._B1_ACTIVE_CACHE = (0.0, False)
                self.assertFalse(health._b1_expected_active())
                run.assert_called_once()

    def test_muted_b1_source_skips_quality_sampling(self):
        import tempfile
        from unittest.mock import patch
        from subprocess import CompletedProcess
        with tempfile.TemporaryDirectory() as temp_dir:
            router_config = pathlib.Path(temp_dir) / "roaring_mic_router.conf"
            router_config.write_text('B1_ACTIVE="true"\nCARLA_TO_B1="true"\n')
            outputs = [
                CompletedProcess([], 0, stdout="Mute: no\n", stderr=""),
                CompletedProcess([], 0, stdout="Mute: yes\n", stderr=""),
            ]
            with patch.object(health, "ROUTER_CONFIG_PATH", router_config), \
                 patch.object(health, "_run_checked", side_effect=outputs) as run:
                health._B1_ACTIVE_CACHE = (0.0, False)
                self.assertFalse(health._b1_expected_active())
                self.assertEqual(run.call_count, 2)

    def test_sample_cycle_does_not_open_capture_when_b1_is_muted(self):
        from unittest.mock import patch
        stored = {}
        with patch.object(health, "_b1_expected_active", return_value=False), \
             patch.object(health, "capture_sample") as capture, \
             patch.object(health, "_read_state", return_value={}), \
             patch.object(health, "_write_state", side_effect=lambda value: stored.update(value)), \
             patch.object(health, "_record_sample"), \
             patch.object(health, "notify") as notify:
            code = health.run_sample_cycle(8.0, {"AUTO_RECOVER": True, "NOTIFY": True})
        self.assertEqual(code, 0)
        capture.assert_not_called()
        notify.assert_not_called()
        self.assertEqual(stored["last_verdict"], "MUTED")
        self.assertEqual(stored["last_sample"]["windows"], 0)

    def test_capture_sample_returns_muted_without_opening_taps(self):
        from unittest.mock import patch
        with patch.object(health, "_b1_expected_active", return_value=False), \
             patch.object(health, "_start_capture") as start_capture:
            result = health.capture_sample(8.0)
        self.assertEqual(result["verdict"], "MUTED")
        start_capture.assert_not_called()

class CarlaWatcherRouterAuthorityTests(unittest.TestCase):
    def _load_router_state(self, text):
        import tempfile
        script = ROOT / "Bin/roaring_carla_watchd.sh"
        shell = r"""set -euo pipefail
ROUTER_CONF="$CONF"
source <(sed -n '/^read_router_flag() {/,/^}/p' "$WATCHER")
source <(sed -n '/^load_bus_state() {/,/^}/p' "$WATCHER")
if load_bus_state; then printf '%s %s' "$B1_PROCESSED" "$B2_PROCESSED"; else echo unavailable; fi
"""
        with tempfile.TemporaryDirectory() as temp_dir:
            conf = pathlib.Path(temp_dir) / "roaring_mic_router.conf"
            if text is not None:
                conf.write_text(text)
            result = subprocess.run(
                ["bash", "-c", shell], capture_output=True, text=True,
                env={**os.environ, "WATCHER": str(script), "CONF": str(conf)},
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_watcher_obeys_active_carla_to_bus_flags(self):
        config = (
            'B1_ACTIVE="true"\nCARLA_TO_B1="true"\n'
            'B2_ACTIVE="true"\nCARLA_TO_B2="false"\n'
        )
        self.assertEqual(self._load_router_state(config), "1 0")

    def test_disabled_b1_and_b2_are_never_relinked(self):
        config = (
            'B1_ACTIVE="false"\nCARLA_TO_B1="true"\n'
            'B2_ACTIVE="false"\nCARLA_TO_B2="true"\n'
        )
        self.assertEqual(self._load_router_state(config), "0 0")

    def test_missing_router_config_fails_closed(self):
        self.assertEqual(self._load_router_state(None).strip(), "unavailable")

    def test_watcher_has_no_conflicting_hardcoded_b2_default(self):
        source = (ROOT / "Bin/roaring_carla_watchd.sh").read_text()
        self.assertIn("ROUTER_CONF", source)
        self.assertIn("CARLA_TO_B1", source)
        self.assertIn("CARLA_TO_B2", source)
        self.assertNotIn("B2_PROCESSED:-1", source)


class CarlaHealthDeploymentTests(unittest.TestCase):
    def test_health_unit_is_bounded_oneshot_with_no_persistent_capture(self):
        unit = (ROOT / "User/roaring-carla-healthd.service").read_text()
        self.assertIn("Type=oneshot", unit)
        self.assertIn("ExecStart=%h/bin/roaring_carla_healthd.py --sample-seconds 8", unit)
        self.assertIn("CPUQuota=15%", unit)
        self.assertIn("MemoryMax=96M", unit)
        self.assertIn("TimeoutStartSec=180", unit)
        self.assertNotIn("Restart=on-failure", unit)
        self.assertIn("ProtectSystem=strict", unit)
        self.assertIn("ReadWritePaths=-%h/.cache/roaring", unit)

    def test_health_timer_runs_infrequently_and_only_when_enabled(self):
        timer = (ROOT / "User/roaring-carla-healthd.timer").read_text()
        self.assertIn("OnBootSec=3min", timer)
        self.assertIn("OnUnitActiveSec=10min", timer)
        self.assertIn("RandomizedDelaySec=45s", timer)
        installer = (ROOT / "Bin/install_roaring_carla_healthd.sh").read_text()
        self.assertIn("--enable-sampler", installer)
        self.assertIn('if (( enable_sampler )); then', installer)
        self.assertIn("disable --now roaring-carla-healthd.service", installer)
        self.assertIn("install -m 0600", installer)
        self.assertIn("daemon-reload", installer)

class PipeWireClockMetadataTests(unittest.TestCase):
    def test_zero_force_rate_falls_back_to_normal_clock_rate(self):
        from subprocess import CompletedProcess
        from unittest.mock import patch
        outputs = [
            CompletedProcess(["pw-top"], 0, stdout="", stderr=""),
            CompletedProcess(
                ["pw-metadata"], 0,
                stdout=(
                    "update: id:0 key:'clock.rate' value:'48000' type:''\n"
                    "update: id:0 key:'clock.force-rate' value:'0' type:''\n"
                    "update: id:0 key:'clock.quantum' value:'1024' type:''\n"
                    "update: id:0 key:'clock.force-quantum' value:'512' type:''\n"
                ),
                stderr="",
            ),
        ]
        with patch.object(health, "_run_checked", side_effect=outputs):
            snapshot = health._read_pipewire_health()
        self.assertEqual(snapshot["rate"], 48000)
        self.assertEqual(snapshot["quantum"], 512)


class CaptureBufferDrainTests(unittest.TestCase):
    def test_drain_consumes_all_paired_blocks_and_keeps_unmatched_tail(self):
        import array
        raw = array.array("f", [0.1, 0.2, 0.3, 0.4] * 3).tobytes()
        post = array.array("f", [0.5, 0.6, 0.7, 0.8] * 2).tobytes()
        buffers = {health.RAW_SOURCE: bytearray(raw), health.PROCESSED_SOURCE: bytearray(post)}
        pairs = health._drain_aligned_blocks(buffers, 4)
        self.assertEqual(len(pairs), 2)
        self.assertEqual(len(buffers[health.RAW_SOURCE]), 16)
        self.assertEqual(len(buffers[health.PROCESSED_SOURCE]), 0)
        for actual, expected in zip(pairs[0][0], [0.1, 0.2, 0.3, 0.4]):
            self.assertAlmostEqual(actual, expected, places=6)
        for actual, expected in zip(pairs[1][1], [0.5, 0.6, 0.7, 0.8]):
            self.assertAlmostEqual(actual, expected, places=6)

    def test_drain_does_not_emit_when_either_tap_has_only_a_partial_block(self):
        import array
        buffers = {
            health.RAW_SOURCE: bytearray(array.array("f", [0.1] * 4).tobytes()),
            health.PROCESSED_SOURCE: bytearray(array.array("f", [0.2] * 3).tobytes()),
        }
        self.assertEqual(health._drain_aligned_blocks(buffers, 4), [])
        self.assertEqual(len(buffers[health.RAW_SOURCE]), 16)
        self.assertEqual(len(buffers[health.PROCESSED_SOURCE]), 12)


class CaptureTapConfigurationTests(unittest.TestCase):
    def test_capture_tap_requests_graph_aligned_ten_millisecond_latency(self):
        from unittest.mock import patch
        sentinel = object()
        with patch.object(health.subprocess, "Popen", return_value=sentinel) as popen:
            self.assertIs(health._start_capture("sm7b_mono", "test-stream"), sentinel)
        command = popen.call_args.args[0]
        self.assertIn("--latency-msec=10", command)
        self.assertNotIn("--latency-msec=20", command)
        self.assertIn("--format=float32le", command)


class QualityTrackerLatchTests(unittest.TestCase):
    def test_latch_requires_twenty_seconds_of_clean_correlated_speech(self):
        tracker = health.QualityTracker()
        tracker.latched = True
        clean = {"valid": True, "candidate": False, "dropout": False}
        tracker.observe(clean, 10.0)
        tracker.observe(clean, 29.9)
        self.assertTrue(tracker.latched)
        tracker.observe(clean, 30.0)
        self.assertFalse(tracker.latched)

    def test_any_new_candidate_resets_the_clean_latch_timer(self):
        tracker = health.QualityTracker()
        tracker.latched = True
        clean = {"valid": True, "candidate": False, "dropout": False}
        noisy = {"valid": True, "candidate": True, "dropout": False}
        tracker.observe(clean, 10.0)
        tracker.observe(noisy, 20.0)
        tracker.observe(clean, 25.0)
        tracker.observe(clean, 44.9)
        self.assertTrue(tracker.latched)
        tracker.observe(clean, 45.0)
        self.assertFalse(tracker.latched)


class CarlaSafeRestartSequenceTests(unittest.TestCase):
    def _backend(self, pid=321, gui=False):
        argv = ["/usr/bin/python3", "/app/share/carla/carla"]
        if not gui:
            argv.append("--no-gui")
        argv.append("/home/test/CarlaProject.carxp")
        return (pid, argv, "0::/user.slice/test-carla.scope")

    def _completed(self, args, returncode=0, stdout=""):
        return subprocess.CompletedProcess(args, returncode, stdout=stdout, stderr="")

    def test_successful_restart_proves_old_backend_gone_before_starting_canonical(self):
        old_alive = {"value": True}
        events = []
        wait_index = {"value": 0}
        process = self._backend()

        def processes():
            return [process] if old_alive["value"] else []

        def run_checked(args, timeout=15.0):
            events.append(("command", tuple(args)))
            if args[:2] == ["flatpak", "kill"]:
                old_alive["value"] = False
            if args[:4] == ["systemctl", "--user", "show", health.CANONICAL_SERVICE]:
                return self._completed(args, stdout="LoadState=loaded\nActiveState=inactive\n")
            return self._completed(args)

        def wait_until(predicate, timeout, interval=1.0):
            index = wait_index["value"]
            wait_index["value"] += 1
            value = predicate()
            events.append(("wait", index, value))
            return value

        with patch.object(health, "_b1_expected_active", return_value=True), \
             patch.object(health, "_carla_processes", side_effect=processes), \
             patch.object(health, "_run_checked", side_effect=run_checked), \
             patch.object(health, "_wait_until", side_effect=wait_until), \
             patch.object(health, "_carla_node_present", return_value=True), \
             patch.object(health, "_required_b1_links_present", return_value=True):
            ok, detail = health.restart_carla_safely()

        self.assertTrue(ok, detail)
        commands = [event[1] for event in events if event[0] == "command"]
        flatpak_index = next(i for i, args in enumerate(commands) if args[:2] == ("flatpak", "kill"))
        start_index = next(i for i, args in enumerate(commands) if args[:3] == ("systemctl", "--user", "start"))
        first_wait = next(i for i, event in enumerate(events) if event[:2] == ("wait", 0))
        start_event = next(i for i, event in enumerate(events) if event[0] == "command" and event[1][:3] == ("systemctl", "--user", "start"))
        self.assertLess(next(i for i, event in enumerate(events) if event[0] == "command" and event[1][:2] == ("flatpak", "kill")), first_wait)
        self.assertLess(first_wait, start_event)
        self.assertEqual(commands[start_index][:4], ("systemctl", "--user", "start", health.CANONICAL_SERVICE))
        self.assertEqual(wait_index["value"], 3)
        self.assertIn("B1 links verified", detail)

    def test_disabled_or_muted_b1_refuses_recovery_before_inspecting_processes(self):
        with patch.object(health, "_b1_expected_active", return_value=False), \
             patch.object(health, "_carla_processes") as processes, \
             patch.object(health, "_run_checked") as run:
            ok, detail = health.restart_carla_safely()
        self.assertFalse(ok)
        self.assertIn("disabled or muted", detail)
        processes.assert_not_called()
        run.assert_not_called()

    def test_multiple_backends_refuse_recovery_without_any_stop_command(self):
        with patch.object(health, "_b1_expected_active", return_value=True), \
             patch.object(health, "_carla_processes", return_value=[self._backend(321), self._backend(322)]), \
             patch.object(health, "_run_checked") as run:
            ok, detail = health.restart_carla_safely()
        self.assertFalse(ok)
        self.assertIn("found 2", detail)
        run.assert_not_called()

    def test_interactive_carla_session_is_never_stopped(self):
        with patch.object(health, "_b1_expected_active", return_value=True), \
             patch.object(health, "_carla_processes", return_value=[self._backend(gui=True)]), \
             patch.object(health, "_run_checked") as run:
            ok, detail = health.restart_carla_safely()
        self.assertFalse(ok)
        self.assertIn("editing session", detail)
        run.assert_not_called()

    def test_uninstalled_canonical_unit_refuses_before_stopping_anything(self):
        with patch.object(health, "_b1_expected_active", return_value=True), \
             patch.object(health, "_carla_processes", return_value=[self._backend()]), \
             patch.object(health, "_run_checked", return_value=self._completed([], stdout="LoadState=not-found\n")) as run:
            ok, detail = health.restart_carla_safely()
        self.assertFalse(ok)
        self.assertIn("not installed", detail)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0][:4], ["systemctl", "--user", "show", health.CANONICAL_SERVICE])

    def test_canonical_stop_failure_prevents_transient_or_flatpak_kill(self):
        def run_checked(args, timeout=15.0):
            if args[:3] == ["systemctl", "--user", "stop"] and args[3] == health.CANONICAL_SERVICE:
                return self._completed(args, returncode=1)
            if args[:3] == ["systemctl", "--user", "show"]:
                return self._completed(args, stdout="LoadState=loaded\n")
            return self._completed(args)
        with patch.object(health, "_b1_expected_active", return_value=True), \
             patch.object(health, "_carla_processes", return_value=[self._backend()]), \
             patch.object(health, "_run_checked", side_effect=run_checked) as run:
            ok, detail = health.restart_carla_safely()
        self.assertFalse(ok)
        self.assertIn("could not stop", detail)
        self.assertEqual(run.call_count, 2)
        self.assertNotIn(["flatpak", "kill", health.CARLA_APP_ID], [call.args[0] for call in run.call_args_list])

    def test_unproven_backend_exit_never_starts_replacement_engine(self):
        commands = []
        def run_checked(args, timeout=15.0):
            commands.append(list(args))
            if args[:3] == ["systemctl", "--user", "show"]:
                return self._completed(args, stdout="LoadState=loaded\n")
            return self._completed(args)
        with patch.object(health, "_b1_expected_active", return_value=True), \
             patch.object(health, "_carla_processes", return_value=[self._backend()]), \
             patch.object(health, "_run_checked", side_effect=run_checked), \
             patch.object(health, "_wait_until", return_value=False):
            ok, detail = health.restart_carla_safely()
        self.assertFalse(ok)
        self.assertIn("refusing duplicate launch", detail)
        self.assertNotIn(["systemctl", "--user", "start", health.CANONICAL_SERVICE], commands)

    def test_flatpak_kill_failure_with_backend_still_alive_never_starts_replacement(self):
        commands = []
        def run_checked(args, timeout=15.0):
            commands.append(list(args))
            if args[:3] == ["systemctl", "--user", "show"]:
                return self._completed(args, stdout="LoadState=loaded\n")
            if args[:2] == ["flatpak", "kill"]:
                return self._completed(args, returncode=1)
            return self._completed(args)
        with patch.object(health, "_b1_expected_active", return_value=True), \
             patch.object(health, "_carla_processes", return_value=[self._backend()]), \
             patch.object(health, "_run_checked", side_effect=run_checked):
            ok, detail = health.restart_carla_safely()
        self.assertFalse(ok)
        self.assertIn("Flatpak could not stop", detail)
        self.assertNotIn(["systemctl", "--user", "start", health.CANONICAL_SERVICE], commands)


if __name__ == "__main__":
    unittest.main()
