#!/usr/bin/env python3
"""Compare the raw SM7B tap with processed B1 audio and recover cautiously.

No microphone PCM is written to disk. Samples live only in bounded process
buffers; persistent state contains counters and timing, never audio payloads.
"""
from __future__ import annotations

import argparse
import array
import collections
import json
import logging
import math
import os
import pathlib
import re
import selectors
import signal
import subprocess
import sys
import time
import numpy as np
from typing import Callable, Iterable, Sequence

RATE = 48_000
BLOCK_MS = 100
BLOCK_FRAMES = RATE * BLOCK_MS // 1000
SAMPLE_BYTES = 4
MAX_CAPTURE_BUFFER_BLOCKS = 6
RAW_SOURCE = "sm7b_mono"
PROCESSED_SOURCE = "b1_mic"
CARLA_APP_ID = "studio.kx.carla"
CARLA_PROCESS_ARGV = ("/usr/bin/python3", "/app/share/carla/carla")
CANONICAL_SERVICE = "roaring-carla-session.service"
TRANSIENT_SERVICE = "carla-b1-restart.service"
STATE_PATH = pathlib.Path.home() / ".cache/roaring/carla-healthd-state.json"
CONFIG_PATH = pathlib.Path.home() / ".config/roaring/carla-health.env"
ROUTER_CONFIG_PATH = pathlib.Path.home() / ".config/hearth/roaring_mic_router.conf"
LOG = logging.getLogger("roaring.carla.health")

# Thresholds are deliberately conservative. A candidate must be an output-only
# transient after alignment, not merely a loud consonant in the raw microphone.
VOICE_RMS_FLOOR = 0.008
MIN_CORRELATION = 0.30
MIN_RESIDUAL_HF_PEAK = 0.025
MIN_RESIDUAL_HF_CREST = 15.0
MIN_RESIDUAL_HF_KURTOSIS = 10.0
MAX_RAW_TO_RESIDUAL_HF_PEAK = 0.70
DROPOUT_RAW_RMS = 0.025
DROPOUT_POST_RMS = 0.0015
DROPOUT_RATIO = 0.04
EVENTS_TO_CONFIRM = 3
EVENT_WINDOW_SECONDS = 4.0
RESTART_COOLDOWN_SECONDS = 900
MAX_RESTARTS_PER_HOUR = 2
STARTUP_NODE_TIMEOUT_SECONDS = 90
LINK_TIMEOUT_SECONDS = 20


def _rms(values: Sequence[float]) -> float:
    if len(values) == 0:
        return 0.0
    samples = np.asarray(values, dtype=np.float64)
    return float(np.sqrt(np.mean(samples * samples)))


def _peak(values: Sequence[float]) -> float:
    if len(values) == 0:
        return 0.0
    return float(np.max(np.abs(np.asarray(values, dtype=np.float64))))


def _highpass(values: Sequence[float], cutoff_hz: float = 5000.0) -> np.ndarray:
    """Hamming-windowed FIR high-pass; feature-only, never used on live output."""
    samples = np.asarray(values, dtype=np.float64)
    if samples.size == 0:
        return samples
    taps = 31
    midpoint = (taps - 1) / 2
    normalized = cutoff_hz / RATE
    lowpass = []
    for index in range(taps):
        offset = index - midpoint
        if offset == 0:
            value = 2.0 * normalized
        else:
            value = math.sin(2.0 * math.pi * normalized * offset) / (math.pi * offset)
        window = 0.54 - 0.46 * math.cos(2.0 * math.pi * index / (taps - 1))
        lowpass.append(value * window)
    coefficients = -np.asarray(lowpass, dtype=np.float64)
    coefficients[taps // 2] += 1.0
    padded = np.pad(samples, (taps // 2, taps // 2), mode="reflect")
    return np.convolve(padded, coefficients, mode="valid")


def _excess_kurtosis(values: Sequence[float]) -> float:
    samples = np.asarray(values, dtype=np.float64)
    if samples.size < 4:
        return 0.0
    centered = samples - np.mean(samples)
    second = float(np.mean(centered * centered))
    if second <= 1e-18:
        return 0.0
    fourth = float(np.mean(centered ** 4))
    return fourth / (second * second) - 3.0


def _best_alignment(
    raw: Sequence[float], processed: Sequence[float], *,
    max_lag_samples: int = 960, stride: int = 8,
) -> tuple[int, float]:
    """Return processed delay relative to raw and normalized correlation.

    FFT correlation on a decimated copy bounds the coarse search; a short
    vectorized full-rate refinement restores sample accuracy for the residual.
    """
    x = np.asarray(raw, dtype=np.float64)
    y = np.asarray(processed, dtype=np.float64)
    count = min(x.size, y.size)
    if count < RATE // 20:
        return 0, 0.0
    x = x[:count]
    y = y[:count]
    xd = x[::stride]
    yd = y[::stride]
    xd = xd - np.mean(xd)
    yd = yd - np.mean(yd)
    correlation = np.correlate(yd, xd, mode="full")
    center = xd.size - 1
    max_decimated_lag = min(max_lag_samples // stride, xd.size // 4)
    candidate_lags = np.arange(-max_decimated_lag, max_decimated_lag + 1)
    coarse_lag = int(candidate_lags[int(np.argmax(np.abs(
        correlation[center - max_decimated_lag:center + max_decimated_lag + 1]
    )))]) * stride

    best_lag = coarse_lag
    best_corr = 0.0
    for lag in range(max(-max_lag_samples, coarse_lag - stride),
                     min(max_lag_samples, coarse_lag + stride) + 1):
        if lag >= 0:
            left = x[:count - lag] if lag else x
            right = y[lag:lag + left.size]
        else:
            right = y[:count + lag]
            left = x[-lag:-lag + right.size]
        n = min(left.size, right.size)
        if n < RATE // 100:
            continue
        left = left[:n] - np.mean(left[:n])
        right = right[:n] - np.mean(right[:n])
        denominator = float(np.linalg.norm(left) * np.linalg.norm(right))
        value = float(np.dot(left, right) / denominator) if denominator > 1e-18 else 0.0
        if abs(value) > abs(best_corr):
            best_corr = value
            best_lag = lag
    return best_lag, abs(best_corr)


def analyze_pair(raw: Sequence[float], processed: Sequence[float]) -> dict[str, float | int | bool]:
    """Analyze one bounded PCM window without retaining or returning samples."""
    raw = np.asarray(raw, dtype=np.float64)
    processed = np.asarray(processed, dtype=np.float64)
    count = min(raw.size, processed.size)
    if count < RATE // 50:
        return {"valid": False, "candidate": False, "dropout": False}
    raw = raw[:count]
    processed = processed[:count]
    raw_rms = _rms(raw)
    post_rms = _rms(processed)
    lag, correlation = _best_alignment(raw, processed)
    result: dict[str, float | int | bool] = {
        "valid": correlation >= MIN_CORRELATION and raw_rms >= VOICE_RMS_FLOOR,
        "candidate": False,
        "dropout": False,
        "raw_rms": raw_rms,
        "post_rms": post_rms,
        "correlation": correlation,
        "lag_samples": lag,
        "gain": 0.0,
        "residual_hf_peak": 0.0,
        "residual_hf_crest": 0.0,
        "residual_hf_kurtosis": 0.0,
        "raw_hf_peak": 0.0,
    }
    if raw_rms >= DROPOUT_RAW_RMS and (
        post_rms <= DROPOUT_POST_RMS or post_rms / raw_rms <= DROPOUT_RATIO
    ):
        # An intentionally disabled/muted B1 bus is not a processing failure.
        result["dropout"] = _b1_expected_active()
        return result
    if correlation < MIN_CORRELATION or raw_rms < VOICE_RMS_FLOOR:
        return result

    if lag >= 0:
        x = raw[:count - lag] if lag else raw
        y = processed[lag:lag + x.size]
    else:
        y = processed[:count + lag]
        x = raw[-lag:-lag + y.size]
    n = min(x.size, y.size)
    if n < RATE // 50:
        result["valid"] = False
        return result
    x = x[:n]
    y = y[:n]
    denominator = float(np.dot(x, x))
    gain = float(np.dot(x, y) / denominator) if denominator > 1e-15 else 0.0
    residual = y - gain * x
    raw_hf = _highpass(x)
    residual_hf = _highpass(residual)
    raw_hf_peak = _peak(raw_hf)
    residual_hf_peak = _peak(residual_hf)
    residual_hf_rms = _rms(residual_hf)
    crest = residual_hf_peak / max(residual_hf_rms, 1e-9)
    kurtosis = _excess_kurtosis(residual_hf)
    candidate = (
        residual_hf_peak >= max(MIN_RESIDUAL_HF_PEAK, post_rms * 0.30)
        and crest >= MIN_RESIDUAL_HF_CREST
        and kurtosis >= MIN_RESIDUAL_HF_KURTOSIS
        and raw_hf_peak <= residual_hf_peak * MAX_RAW_TO_RESIDUAL_HF_PEAK
    )
    result.update({
        "gain": gain,
        "raw_hf_peak": raw_hf_peak,
        "residual_hf_peak": residual_hf_peak,
        "residual_hf_crest": crest,
        "residual_hf_kurtosis": kurtosis,
        "candidate": candidate,
    })
    return result

class QualityTracker:
    def __init__(self) -> None:
        self.events: collections.deque[float] = collections.deque()
        self.dropout_streak = 0
        self.latched = False
        self.clean_since: float | None = None

    def observe(self, result: dict[str, float | int | bool], now: float) -> bool:
        if self.latched:
            clean = bool(result.get("valid")) and not bool(result.get("candidate")) and not bool(result.get("dropout"))
            if clean:
                if self.clean_since is None:
                    self.clean_since = now
                elif now - self.clean_since >= 20.0:
                    self.reset_after_recovery()
            else:
                self.clean_since = None
            return False
        if bool(result.get("dropout")):
            self.dropout_streak += 1
        else:
            self.dropout_streak = 0
        if bool(result.get("candidate")):
            self.events.append(now)
        while self.events and now - self.events[0] > EVENT_WINDOW_SECONDS:
            self.events.popleft()
        confirmed = (
            len(self.events) >= EVENTS_TO_CONFIRM or self.dropout_streak >= 3
        )
        if confirmed and not self.latched:
            self.latched = True
            return True
        return False

    def reset_after_recovery(self) -> None:
        self.events.clear()
        self.dropout_streak = 0
        self.latched = False
        self.clean_since = None


def load_config(path: pathlib.Path = CONFIG_PATH) -> dict[str, bool]:
    """Read a tiny allow-listed KEY=VALUE file; never execute it as shell."""
    config = {"AUTO_RECOVER": False, "NOTIFY": True}
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or "=" not in stripped:
                continue
            key, value = (part.strip() for part in stripped.split("=", 1))
            if key not in config:
                continue
            config[key] = value.lower() in {"1", "yes", "true", "on"}
    except FileNotFoundError:
        pass
    return config


def notify(title: str, body: str, *, urgency: str = "critical") -> None:
    try:
        subprocess.run(
            ["notify-send", "--app-name=Roaring Audio", "--icon=audio-input-microphone",
             f"--urgency={urgency}", "--expire-time=12000", title, body],
            check=False, timeout=4, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.TimeoutExpired):
        LOG.warning("KDE notification unavailable: %s - %s", title, body)


_B1_ACTIVE_CACHE: tuple[float, bool] = (0.0, False)


def _b1_expected_active() -> bool:
    """Do not diagnose an intentionally disabled or muted B1 bus as a dropout."""
    global _B1_ACTIVE_CACHE
    cached_until, cached_value = _B1_ACTIVE_CACHE
    now = time.monotonic()
    if now < cached_until:
        return cached_value
    flags: dict[str, str] = {}
    try:
        for line in ROUTER_CONFIG_PATH.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or "=" not in stripped:
                continue
            key, value = (part.strip().strip('"').strip("'") for part in stripped.split("=", 1))
            if key in {"B1_ACTIVE", "CARLA_TO_B1"}:
                flags[key] = value.lower()
    except OSError:
        _B1_ACTIVE_CACHE = (now + 2.0, False)
        return False
    if flags.get("B1_ACTIVE") != "true" or flags.get("CARLA_TO_B1") != "true":
        _B1_ACTIVE_CACHE = (now + 2.0, False)
        return False
    try:
        mute = _run_checked(["pactl", "get-sink-mute", "mic_b1"], timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        _B1_ACTIVE_CACHE = (now + 2.0, False)
        return False
    active = mute.returncode == 0 and "Mute: no" in mute.stdout
    _B1_ACTIVE_CACHE = (now + 2.0, active)
    return active


def _carla_processes(proc_root: pathlib.Path = pathlib.Path("/proc")) -> list[tuple[int, list[str], str]]:
    found = []
    try:
        entries = list(proc_root.iterdir())
    except OSError:
        return found
    for entry in entries:
        if not entry.name.isdigit():
            continue
        try:
            argv = [part.decode("utf-8", "replace") for part in (entry / "cmdline").read_bytes().split(b"\0") if part]
            if len(argv) >= 2 and argv[0] in CARLA_PROCESS_ARGV[:1] and argv[1] == CARLA_PROCESS_ARGV[1]:
                cgroup = (entry / "cgroup").read_text(encoding="utf-8", errors="replace")
                found.append((int(entry.name), argv, cgroup))
        except (OSError, ProcessLookupError):
            continue
    return found



def parse_pw_top(text: str) -> dict[str, dict[str, int | str]]:
    """Parse pw-top's stable column layout; ignore rows without numeric ERR."""
    result: dict[str, dict[str, int | str]] = {}
    markers = {
        "scarlett": "alsa_input.usb-Focusrite_Scarlett_Solo",
        "carla": "Carla",
        "b1": "b1_mic",
    }
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 9 or fields[0] not in {"E", "S", "I", "R", "t", "T", "!"}:
            continue
        try:
            quantum = int(fields[2])
            rate = int(fields[3])
            errors = int(fields[8])
        except (ValueError, IndexError):
            continue
        for key, marker in markers.items():
            if marker not in line:
                continue
            # "b1_mic" appears in both the bus and capture source rows; keep
            # the first concrete row but prefer the named b1_mic node itself.
            if key == "b1" and "input.b1_mic" in line:
                node_name = "input.b1_mic"
            else:
                node_name = marker
            candidate = {
                "id": int(fields[1]), "status": fields[0], "quantum": quantum,
                "rate": rate, "errors": errors, "name": node_name,
            }
            previous = result.get(key)
            replace = previous is None
            if previous is not None:
                # ERR is cumulative for one node ID, so prefer the largest
                # value observed in the batch rather than a later suspended
                # row whose profiler fields are zeroed.
                same_node = candidate["id"] == previous.get("id")
                if not same_node:
                    replace = fields[0] == "R" and previous.get("status") != "R"
                elif errors > int(previous.get("errors", 0)):
                    replace = True
                elif fields[0] == "R" and previous.get("status") != "R":
                    replace = True
                if key == "b1" and node_name == "b1_mic":
                    replace = True
            if replace:
                result[key] = candidate
    return result


def _read_pipewire_health() -> dict[str, object]:
    """Take a bounded metadata and pw-top snapshot; no PCM is stored."""
    snapshot: dict[str, object] = {"nodes": {}, "quantum": None, "rate": None}
    try:
        top = _run_checked(["pw-top", "-b", "-n", "6"], timeout=8)
        if top.returncode == 0:
            snapshot["nodes"] = parse_pw_top(top.stdout)
    except (OSError, subprocess.TimeoutExpired):
        LOG.warning("pw-top health snapshot unavailable")
    try:
        metadata = _run_checked(["pw-metadata", "-n", "settings"], timeout=4)
        if metadata.returncode == 0:
            for forced_key, normal_key, out_key in (
                ("clock.force-quantum", "clock.quantum", "quantum"),
                ("clock.force-rate", "clock.rate", "rate"),
            ):
                forced = re.search(rf"key:'{forced_key}' value:'([0-9]+)'", metadata.stdout)
                normal = re.search(rf"key:'{normal_key}' value:'([0-9]+)'", metadata.stdout)
                forced_value = int(forced.group(1)) if forced else 0
                normal_value = int(normal.group(1)) if normal else 0
                effective = forced_value if forced_value > 0 else normal_value
                if effective > 0:
                    snapshot[out_key] = effective
    except (OSError, subprocess.TimeoutExpired):
        LOG.warning("PipeWire clock metadata unavailable")
    return snapshot


def _report_runtime_deltas(
    snapshot: dict[str, object], state: dict, *, notify_enabled: bool,
    now: float, last_notification: float,
) -> float:
    nodes = snapshot.get("nodes")
    if not isinstance(nodes, dict):
        return last_notification
    previous = state.get("pwtop_counters", {})
    if not isinstance(previous, dict):
        previous = {}
    messages = []
    current: dict[str, int] = {}
    for key, node in nodes.items():
        if not isinstance(node, dict):
            continue
        errors = node.get("errors")
        if not isinstance(errors, int):
            continue
        current[key] = errors
        prior = previous.get(key)
        if isinstance(prior, int) and errors > prior:
            messages.append(f"{key} ERR {prior}->{errors} (+{errors-prior})")
    state["pwtop_counters"] = current
    state["pipewire_quantum"] = snapshot.get("quantum")
    state["pipewire_rate"] = snapshot.get("rate")
    summary = ", ".join(
        f"{key} ERR={node.get('errors')} {node.get('status')}"
        for key, node in nodes.items() if isinstance(node, dict)
    )
    if summary:
        LOG.info("PipeWire graph quantum=%s rate=%s; %s",
                 snapshot.get("quantum"), snapshot.get("rate"), summary)
    if messages:
        detail = "; ".join(messages)
        LOG.error("PipeWire error counter increased: %s", detail)
        if notify_enabled and now - last_notification >= 60:
            notify(
                "Microphone timing errors detected",
                f"PipeWire reported new XRUN/error counts: {detail}. "
                "The existing Scarlett quantum monitor may raise the graph buffer; "
                "check the audio health log.",
                urgency="critical",
            )
            last_notification = now
    return last_notification

def _run_checked(args: list[str], *, timeout: float = 15.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=False, capture_output=True, text=True, timeout=timeout)


def _carla_node_present() -> bool:
    try:
        result = _run_checked(["pw-cli", "ls", "Node"], timeout=4)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0 and 'node.name = "Carla"' in result.stdout


def _link_present(graph: str, output_port: str, input_port: str) -> bool:
    current = ""
    for line in graph.splitlines():
        if line and not line[0].isspace():
            current = line.strip()
            continue
        stripped = line.strip()
        if current == output_port and stripped.startswith("|->"):
            if stripped[3:].strip() == input_port:
                return True
        if current == input_port and stripped.startswith("|<-"):
            if stripped[3:].strip() == output_port:
                return True
    return False


def _required_b1_links_present() -> bool:
    try:
        result = _run_checked(["pw-link", "-l"], timeout=4)
    except (OSError, subprocess.TimeoutExpired):
        return False
    if result.returncode != 0 or not result.stdout.strip():
        return False
    graph = result.stdout
    return all((
        _link_present(graph, "sm7b_mono:capture_MONO", "Carla:audio-in1"),
        _link_present(graph, "sm7b_mono:capture_MONO", "Carla:audio-in2"),
        _link_present(graph, "Carla:audio-out1", "mic_b1:playback_FL"),
        _link_present(graph, "Carla:audio-out2", "mic_b1:playback_FR"),
    ))


def _wait_until(predicate: Callable[[], bool], timeout: float, interval: float = 1.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


def restart_carla_safely() -> tuple[bool, str]:
    """Restart the single headless Flatpak Carla engine under canonical systemd.

    The Flatpak app is launched in its own transient app scope, which can outlive
    the initiating systemd wrapper. Therefore we stop wrappers, explicitly kill
    the Flatpak app, prove the exact backend process is gone, and only then start
    the canonical session. Ambiguous ownership or multiple backends fail closed.
    """
    if not _b1_expected_active():
        return False, "B1 is disabled or muted; refusing to restart Carla"
    processes = _carla_processes()
    if len(processes) != 1:
        return False, f"expected exactly one Carla backend; found {len(processes)}"
    pid, argv, _cgroup = processes[0]
    if "--no-gui" not in argv:
        return False, "Carla is not in headless mode; refusing to interrupt an editing session"

    try:
        canonical = _run_checked(
            ["systemctl", "--user", "show", CANONICAL_SERVICE, "-p", "LoadState", "-p", "ActiveState"],
            timeout=5,
        )
        if canonical.returncode != 0 or "LoadState=loaded" not in canonical.stdout:
            return False, "canonical Carla systemd unit is not installed"
        stop_canonical = _run_checked(["systemctl", "--user", "stop", CANONICAL_SERVICE], timeout=20)
        if stop_canonical.returncode != 0:
            return False, "could not stop the canonical Carla unit"

        # The transient click-to-restart unit may be only the Flatpak launcher;
        # the real app backend has its own transient app.scope.
        _run_checked(["systemctl", "--user", "stop", TRANSIENT_SERVICE], timeout=10)
        killed = _run_checked(["flatpak", "kill", CARLA_APP_ID], timeout=20)
        if killed.returncode != 0 and _carla_processes():
            return False, "Flatpak could not stop Carla; no replacement was started"
        if not _wait_until(lambda: not _carla_processes(), timeout=15, interval=0.25):
            return False, "Carla backend remained alive after Flatpak stop; refusing duplicate launch"

        start = _run_checked(["systemctl", "--user", "start", CANONICAL_SERVICE], timeout=25)
        if start.returncode != 0:
            return False, "canonical Carla service failed to start"
        if not _wait_until(_carla_node_present, STARTUP_NODE_TIMEOUT_SECONDS, interval=1.0):
            return False, "Carla did not publish its PipeWire node after restart"
        if not _wait_until(_required_b1_links_present, LINK_TIMEOUT_SECONDS, interval=1.0):
            return False, "Carla restarted, but the required B1 patchbay links did not return"
        return True, f"Carla restarted (previous backend PID {pid}); B1 links verified"
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, f"recovery command failed safely: {exc}"


def _read_state(path: pathlib.Path | None = None) -> dict:
    path = path or STATE_PATH
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_state(state: dict, path: pathlib.Path | None = None) -> None:
    path = path or STATE_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + f".tmp.{os.getpid()}")
    temp.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temp, 0o600)
    os.replace(temp, path)


def _restart_allowed(state: dict, now: float) -> tuple[bool, str]:
    last = float(state.get("last_restart", 0.0) or 0.0)
    if now - last < RESTART_COOLDOWN_SECONDS:
        return False, "restart cooldown is active"
    recent = [float(v) for v in state.get("restart_times", []) if now - float(v) < 3600]
    if len(recent) >= MAX_RESTARTS_PER_HOUR:
        return False, "restart circuit breaker reached two recoveries in one hour"
    return True, ""


def handle_confirmed_fault(config: dict[str, bool], state: dict) -> tuple[bool, str]:
    now = time.time()
    allowed, reason = _restart_allowed(state, now)
    if not allowed:
        return False, reason
    if not config.get("AUTO_RECOVER", False):
        return False, "automatic recovery is disabled; enable AUTO_RECOVER=1 after validating this detector"
    # Count attempts, not only successful restarts. A broken launcher must not
    # create an unbounded retry loop when the same fault keeps being detected.
    times = [float(v) for v in state.get("restart_times", []) if now - float(v) < 3600]
    times.append(now)
    state["restart_times"] = times
    state["last_restart"] = now
    _write_state(state)
    return restart_carla_safely()


def _start_capture(device: str, stream_name: str) -> subprocess.Popen[bytes]:
    command = [
        "parec", "--raw", "--format=float32le", f"--rate={RATE}", "--channels=1",
        f"--device={device}", "--client-name=Roaring-Carla-Health",
        f"--stream-name={stream_name}", "--latency-msec=10",
    ]
    return subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)


def _array_from_bytes(data: bytearray, frames: int) -> list[float]:
    count = frames * SAMPLE_BYTES
    raw = bytes(data[:count])
    del data[:count]
    values = array.array("f")
    values.frombytes(raw)
    if sys.byteorder != "little":
        values.byteswap()
    return [float(v) for v in values]


def _drain_aligned_blocks(
    buffers: dict[str, bytearray], frames: int
) -> list[tuple[list[float], list[float]]]:
    """Drain every full common window; leave only unmatched partial tail bytes."""
    need = frames * SAMPLE_BYTES
    pairs: list[tuple[list[float], list[float]]] = []
    while len(buffers[RAW_SOURCE]) >= need and len(buffers[PROCESSED_SOURCE]) >= need:
        pairs.append((
            _array_from_bytes(buffers[RAW_SOURCE], frames),
            _array_from_bytes(buffers[PROCESSED_SOURCE], frames),
        ))
    return pairs


def run_daemon(stop: Callable[[], bool] | None = None) -> int:
    stop = stop or (lambda: False)
    config = load_config()
    LOG.info("starting (raw=%s, processed=%s, rate=%s, auto_recover=%s)",
             RAW_SOURCE, PROCESSED_SOURCE, RATE, config["AUTO_RECOVER"])
    LOG.info("microphone PCM is analyzed in memory only; no raw audio is written to disk")

    processes: dict[str, subprocess.Popen[bytes]] = {}
    buffers = {RAW_SOURCE: bytearray(), PROCESSED_SOURCE: bytearray()}
    selector = selectors.DefaultSelector()
    tracker = QualityTracker()
    state = _read_state()
    last_fault_notification = 0.0
    last_status = 0.0
    last_runtime_notification = 0.0

    def start_one(device: str) -> None:
        proc = _start_capture(device, f"volatile-{device}")
        if proc.stdout is None:
            raise RuntimeError(f"parec did not provide stdout for {device}")
        processes[device] = proc
        selector.register(proc.stdout, selectors.EVENT_READ, device)
        LOG.info("capture tap connected: %s", device)

    try:
        start_one(RAW_SOURCE)
        start_one(PROCESSED_SOURCE)
        while not stop():
            for key, _ in selector.select(timeout=0.1):
                device = key.data
                try:
                    chunk = os.read(key.fileobj.fileno(), 65536)
                except OSError:
                    chunk = b""
                if chunk:
                    buffers[device].extend(chunk)
                    # A stalled capture peer must not let the other tap's PCM
                    # buffer grow indefinitely. Drop only complete float32
                    # samples and retain the newest bounded window.
                    max_bytes = BLOCK_FRAMES * SAMPLE_BYTES * MAX_CAPTURE_BUFFER_BLOCKS
                    if len(buffers[device]) > max_bytes:
                        excess = len(buffers[device]) - max_bytes
                        excess -= excess % SAMPLE_BYTES
                        del buffers[device][:excess]
                        LOG.warning("discarded stale buffered samples from stalled %s tap", device)
            if stop():
                break
            if any(processes[k].poll() is not None for k in list(processes)):
                for device in (RAW_SOURCE, PROCESSED_SOURCE):
                    proc = processes.get(device)
                    if proc is not None and proc.poll() is not None:
                        LOG.warning("capture tap %s exited; restarting reader", device)
                        try:
                            selector.unregister(proc.stdout)
                        except Exception:
                            pass
                        processes.pop(device, None)
                        buffers[device].clear()
                        start_one(device)
                tracker.reset_after_recovery()
                continue
            for raw, processed in _drain_aligned_blocks(buffers, BLOCK_FRAMES):
                result = analyze_pair(raw, processed)
                now_mono = time.monotonic()
                if now_mono - last_status >= 30:
                    LOG.info("quality observer active: raw_rms=%.5f post_rms=%.5f corr=%.2f lag=%s samples",
                             float(result.get("raw_rms", 0.0)), float(result.get("post_rms", 0.0)),
                             float(result.get("correlation", 0.0)), int(result.get("lag_samples", 0)))
                    runtime = _read_pipewire_health()
                    last_runtime_notification = _report_runtime_deltas(
                        runtime, state, notify_enabled=config.get("NOTIFY", True),
                        now=time.time(), last_notification=last_runtime_notification,
                    )
                    last_status = now_mono
                if tracker.observe(result, now_mono):
                    LOG.error(
                        "B1 processing degradation suspected: output-only transient/dropout pattern "
                        "(correlation=%.2f residual_hf_peak=%.4f crest=%.1f kurtosis=%.1f)",
                        float(result.get("correlation", 0.0)),
                        float(result.get("residual_hf_peak", 0.0)),
                        float(result.get("residual_hf_crest", 0.0)),
                        float(result.get("residual_hf_kurtosis", 0.0)),
                    )
                    success, detail = handle_confirmed_fault(config, state)
                    if config.get("NOTIFY", True) and now_mono - last_fault_notification >= 30:
                        title = "B1 microphone crackling suspected"
                        body = detail if success else f"{detail}. Check the audio health log."
                        notify(title, body, urgency="critical")
                        last_fault_notification = now_mono
                    if success:
                        LOG.warning("%s", detail)
                        state = _read_state()
                        tracker.reset_after_recovery()
                    else:
                        LOG.error("automatic recovery not performed: %s", detail)
                        # Latch until 20 seconds of clean, correlated speech, so the
                        # daemon does not generate repeated notices for one incident.
                        tracker.reset_after_recovery()
                        tracker.latched = True
                elif tracker.latched and bool(result.get("valid")) and not bool(result.get("candidate")):
                    tracker.reset_after_recovery()
    except KeyboardInterrupt:
        pass
    except (OSError, RuntimeError) as exc:
        LOG.exception("health observer stopped: %s", exc)
        return 1
    finally:
        for proc in processes.values():
            try:
                proc.terminate()
            except OSError:
                pass
        for proc in processes.values():
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        selector.close()
    LOG.info("stopped")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="print detected Carla process and B1 graph state")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if args.check:
        print(json.dumps({
            "carla_processes": [{"pid": pid, "argv": argv, "cgroup": cgroup}
                                for pid, argv, cgroup in _carla_processes()],
            "carla_node": _carla_node_present(),
            "b1_expected_active": _b1_expected_active(),
            "b1_links": _required_b1_links_present(),
            "pipewire": _read_pipewire_health(),
            "auto_recover": load_config()["AUTO_RECOVER"],
        }, indent=2))
        return 0
    stopped = False

    def request_stop(_signum: int, _frame: object) -> None:
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    return run_daemon(lambda: stopped)


if __name__ == "__main__":
    raise SystemExit(main())
