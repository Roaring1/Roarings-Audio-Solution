# Intermittent Carla B1 audio check

## Operating model

The quality sampler is NOT a daemon. A user systemd timer starts an 8-second
oneshot check approximately every 10 minutes. The service exits after each
sample and closes both parec microphone taps. Between runs it captures no
microphone audio and consumes no sampler CPU or memory.

Files:

- User/roaring-carla-healthd.service - bounded 8-second oneshot sampler.
- User/roaring-carla-healthd.timer - starts it after login/boot and then at
  10-minute intervals with up to 45 seconds of jitter.
- Bin/roaring_carla_healthd.py - short in-memory sampling, classification,
  numeric history and guarded restart/recheck.
- ~/.cache/roaring/carla-health-history.jsonl - last 256 numeric summaries;
  no PCM, transcriptions, or audio payloads.
- ~/.cache/roaring/carla-healthd-state.json - latest verdict and restart
  circuit-breaker state.

The separate roaring-carla-watchd.service is a routing maintainer, not an
audio sampler. It checks the PipeWire graph every few seconds and restores
only links authorized by the Hearth router configuration. It stays active so
a Carla restart can regain its B1 links; it does not open microphone capture
taps or write audio.

## Verdicts

Each sample compares aligned 100 ms windows from:

sm7b_mono -> Carla -> mic_b1 -> b1_mic

The comparison uses normalized correlation, output-only high-frequency
transients, and input-present/output-missing dropout evidence.

- CORRECT - enough active raw-input windows, with at least 60% valid
  raw-to-processed correspondence and no detected quality events.
- NO_SAMPLE - insufficient microphone activity. No restart is attempted.
- INCONCLUSIVE - activity exists but too few windows are comparable. No
  restart is attempted.
- SUSPECT - an isolated transient/dropout candidate occurred but did not
  meet the repeated-fault threshold. No restart is attempted.
- INCORRECT - three output-only impulse candidates within four seconds, or
  three consecutive dropout windows, confirm a fault.

The initial raw activity floor is 0.00025, derived from a short live numeric
survey on this machine (quiet median 0.000057; 99th percentile 0.001153).
The dropout gate is 0.0012 raw RMS and additionally requires a very quiet
processed path. These are initial deployment thresholds, not a final
human-perception classifier. Numeric history is retained so subsequent
intermittent samples can refine them. Quiet windows are never treated as proof
of a fault.

## Recovery behavior

AUTO_RECOVER=1 enables recovery only after a high-confidence INCORRECT
verdict. A confirmed fault causes at most one guarded Carla restart, followed
by exactly one fresh 8-second verification sample:

- RECOVERED - the verification sample is CORRECT.
- STILL_INCORRECT - a second fault is confirmed; it does not trigger another
  restart in the same cycle.
- RECHECK_INCONCLUSIVE - the post-restart sample lacks enough activity or
  cannot establish a clean path. No additional restart is attempted.

Restart safety checks remain mandatory: B1 must be enabled and unmuted; exactly
one known headless Carla backend must exist; the canonical session unit must
be installed; the old backend must be proven gone before replacement start;
and the Carla node plus all four B1 links must return. Restart attempts are
limited to one per 15 minutes and two per hour. Unknown or multiple Carla
owners fail closed.

NOTIFY=1 sends notifications for confirmed faults/recovery outcomes. Routine
CORRECT results are logged and stored, not announced every 10 minutes.
NO_SAMPLE, INCONCLUSIVE, and SUSPECT never cause a restart.

## Installation and operation

From the repository root, run:

    Bin/install_roaring_carla_healthd.sh --enable-sampler

This installs the service and timer, stops/disables any legacy continuous
healthd service, and enables the intermittent timer. It does not restart Carla
during installation.

Check the timer and last verdict:

    systemctl --user status roaring-carla-healthd.timer
    systemctl --user list-timers roaring-carla-healthd.timer
    ~/bin/roaring_carla_healthd.py --status
    journalctl --user -u roaring-carla-healthd.service -n 40

Run one immediate sample manually:

    systemctl --user start roaring-carla-healthd.service

Pause all microphone sampling:

    systemctl --user disable --now roaring-carla-healthd.timer

The unit has a 15% CPU quota, 96 MiB memory cap, low scheduling priority and
a bounded runtime. No microphone tap remains open between samples. The
legacy continuous mode exists only for explicit manual diagnostics:
roaring_carla_healthd.py --continuous; it is not used by systemd.

## Live pause status - 2026-11-10

The owner is temporarily not using the microphone. The installed sampler has
therefore been deliberately parked:

- `roaring-carla-healthd.timer` is disabled and inactive.
- `roaring-carla-healthd.service` is stopped/inactive; no sample is running.
- `AUTO_RECOVER=0` in the local runtime config, so manually starting a sample
  cannot trigger automatic Carla recovery during this break.
- The installed script, service, timer, numeric history, and state files are
  retained. No PCM files are created or need cleanup.
- The separate `roaring-carla-watchd.service` remains active only to maintain
  Carla patchbay links. It does not open microphone capture taps.

This is a temporary runtime pause, not a code or configuration deletion.
When microphone use resumes, inspect current B1 routing and Carla ownership
first, then explicitly re-enable sampling. Keep automatic recovery disabled
until the acoustic and process-ownership acceptance tests are complete.

## Initial rollout notes - 2026-11-09

- At initial rollout, AUTO_RECOVER=1 was enabled for the intermittent timer
  only. This historical setting is superseded by the live pause status above.
- Existing live checks show one Carla backend, expected B1 links, 48 kHz /
  512-frame graph, Scarlett ERR=15, B1 ERR=1, Carla ERR=0. These are cumulative
  PipeWire counters; no new increments were observed in the last check.
- The previous always-running observer consumed about 2-3% CPU and held two
  microphone taps open continuously. That continuous service has been retired.
- The remaining validation is acoustic: collect enough numeric samples during
  clean speech, phone audio, and quiet periods; then compare controlled
  output-only clicks/dropouts with the detector. Do not loosen the confirmed
  fault gates from a single isolated sample.
- No raw microphone audio is written to disk or retained between sample runs.

## Detector research

The current residual impulse heuristic is a conservative first stage, not a
validated perceptual classifier. Candidate improvements should be evaluated
against human-labelled clean and faulty samples, including plosives, sibilants,
phone playback, and controlled 0.1-1 ms clicks.

References:
- Essentia ClickDetector documentation:
  https://essentia.upf.edu/reference/std_ClickDetector.html
- Rund et al. (2025), comparison of perceptible impulsive-noise detectors:
  https://link.springer.com/article/10.1186/s13636-024-00389-9
