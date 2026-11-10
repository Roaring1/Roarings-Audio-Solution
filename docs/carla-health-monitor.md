# Carla B1 health observer

## Scope

The observer monitors the processed B1 microphone path:

`sm7b_mono -> Carla -> mic_b1 -> b1_mic`

It opens two short in-memory PCM taps, compares 100 ms windows, and records feature metrics only. Audio samples are not written to disk, uploaded, or included in notifications. Capture buffers are capped at six analysis blocks per tap. The analysis dependency is NumPy; no SciPy is required.

The comparison estimates the pre/post delay, fits a local gain, then checks the residual for output-only high-frequency impulses. It separately detects a loud raw-input / silent-processed dropout, but only when the Hearth router says B1 and Carla-to-B1 are enabled and the B1 sink is unmuted. A single transient is ignored; three events in four seconds or three consecutive dropout windows are required to confirm a candidate.

This is an initial conservative heuristic, not yet a calibrated human-perception classifier. The synthetic test suite covers clean/processed speech, input-side transients, output-only clicks, dropouts, and silence. It still needs a live voiced-speech soak and a controlled diagnostic capture during a real crackle incident before automatic restart should be enabled.

## Runtime diagnostics

Every 30 seconds it samples:

- PipeWire `pw-top` node states and ERR counters for Scarlett capture, Carla, and B1.
- The effective `clock.force-quantum` / `clock.quantum` and graph rate.
- Aligned raw/post audio quality features.

The ERR field is cumulative xruns plus errors, not a direct acoustic-quality measurement. The observer alerts only on counter increases after its own baseline. The existing Moonlight sender remains the owner of graph-quantum escalation; this observer does not compete with it.

## Safe recovery

Carla recovery is deliberately disabled by default:

`~/.config/roaring/carla-health.env`

```ini
AUTO_RECOVER=0
NOTIFY=1
```

When enabled, recovery requires all of the following:

- Confirmed repeated audio-quality fault, not a single click.
- Exactly one known Carla backend process.
- Carla is headless; interactive editing sessions are never interrupted.
- B1 is active, Carla-to-B1 is enabled, and B1 is not muted.
- The canonical `roaring-carla-session.service` is installed.

Recovery stops the canonical wrapper and the known transient B1 restart unit, stops the Flatpak app, proves the backend process has exited, then starts the canonical service. It waits for Carla's PipeWire node and verifies the four B1 input/output links before reporting success. Unknown or multiple Carla owners fail closed. Failed attempts count toward the same persistent cooldown: 15 minutes between attempts and at most two attempts per hour.

The existing patch watcher uses `pw-link -l`, not strict `pw-dump` JSON parsing. It only adds a link after a successful graph query confirms that exact connection is absent. An unavailable or ambiguous graph fails closed.

## Install and validate

On Nobara/Fedora, install NumPy if needed:

`sudo dnf install python3-numpy`

From the repository root:

`Bin/install_roaring_carla_healthd.sh`

This installs the observer, repaired watcher, and user service unit, creates a notification-only config if one does not already exist, and reloads user systemd. It does not start or enable the observer and does not restart Carla.

To activate only the repaired patch watcher after verifying the patchbay parser:

`Bin/install_roaring_carla_healthd.sh --restart-watcher`

To start the observer in notification-only mode:

`Bin/install_roaring_carla_healthd.sh --enable-observer`

Only after real voiced-speech validation should `AUTO_RECOVER=1` be set and the health observer restarted. This setting is separate from enabling the service.

Useful checks:

`systemctl --user status roaring-carla-healthd.service`

`journalctl --user -u roaring-carla-healthd.service -f`

`~/bin/roaring_carla_healthd.py --check`

The health observer never launches a second Carla process. Do not manually start a second Carla engine or the canonical session while a transient Flatpak Carla backend remains alive.

## Current rollout caution (2026-11-09)

The patch watcher has been installed and restarted. It now follows the Hearth router's B1_ACTIVE / CARLA_TO_B1 and B2_ACTIVE / CARLA_TO_B2 flags; the live config is B1 processed, B2 not processed. The four expected B1 links were verified present and both B2 Carla output links were verified absent. The watcher does not depend on the strict graph JSON parser.

The observer unit and script are installed, but the unit remains **disabled and stopped**. Its config remains AUTO_RECOVER=0, NOTIFY=1.

A temporary live test opened both PCM taps using a 20 ms requested latency. Approximately four seconds later the Scarlett cumulative ERR counter increased from 14 to 15; the existing Moonlight xrun watchdog reacted by raising the graph quantum from 512 to 1024 frames and persisted 1024 as the safe quantum. The timing is concerning, but does not prove the additional xrun was caused by the observer. The observer was stopped immediately. No Carla restart was attempted.

Follow-up code changes reduced the requested tap latency to 10 ms, aligned more closely to one 512-frame graph period, and changed the capture loop to drain every complete paired analysis block instead of allowing a backlog to accumulate. The revised version passes the synthetic and existing regression suites, but **has not yet had a second live acoustic trial**. Keep the observer stopped until a controlled trial confirms it does not increase Scarlett ERR. Do not enable automatic Carla recovery until both live capture safety and crackle-detection sensitivity/false-positive behavior have been validated with real voiced speech and known fault examples.

At the last check the graph was 48 kHz / 1024 frames, the persisted safe quantum was 1024, and the observer had no capture clients open. Do not force the graph back to 512 as part of this work; let the existing xrun policy manage any future downshift.
