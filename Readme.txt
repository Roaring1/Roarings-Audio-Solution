Roaring's Audio Solution
=======================

Personal audio routing and control setup for Nobara 43 KDE Plasma. The project
contains the Linux PipeWire/PulseAudio routing scripts, Carla session assets,
user systemd units, and the Windows Moonlight microphone receiver.

Repository layout
-----------------

- Bin/: scripts installed into ~/bin/
- User/: user systemd unit files and their drop-ins
- Carla/: Carla project/session files
- WirePlumber/: WirePlumber configuration and reference scripts
- Windows/: RoaringMic tray receiver and its hidden Task Scheduler launcher
- tests/: portable Python/Bash regression tests

Microphone passthrough
----------------------

The desktop sends 48 kHz, mono, signed 16-bit PCM to the Windows laptop over
UDP port 46001. The preferred source is B1 (b1_mic). For the SM7B path, B1 is
fed through Carla; the A50 boom-mic path is selected independently by the
router config.

The Windows receiver writes the incoming PCM to the VB-Audio Virtual Cable
playback endpoint named "CABLE Input". Applications on Windows select the
corresponding "CABLE Output" recording endpoint.

The Windows tray app reads:

    %LOCALAPPDATA%\RoaringMic\config.json

The config defaults are:

    {
      "Port": 46001,
      "Rate": 48000,
      "PcHost": "192.168.50.123",
      "PreBufMode": "auto",
      "PreBufPkts": 5,
      "Volume": 100
    }

Output volume is a receiver-side PCM gain from 0% to 200%. 100% is unity gain.
Values above 100% can clip; output is saturated safely to signed 16-bit PCM
and the receiver tracks clipped samples. The saved default remains 100%.

The Windows receiver defaults to adaptive buffering. Each receiver session
starts with a two-packet floor, raises the prebuffer when packet arrival gaps
or playback underruns indicate that more protection is needed, and slowly
returns toward the two-packet floor after sustained stable timing. The
WaveOut queue is capped at eight packets and the Windows kernel UDP receive
buffer is capped at 8 KiB (about 85 ms of this PCM stream) to avoid replaying
a deep stale backlog after a scheduling stall. Set PreBufMode to manual to use
the PreBufPkts value (1-8) instead. Live status reports the selected buffer,
arrival-jitter estimate, packet drops, rejected packets, underruns, and clips.

The laptop command channel uses UDP port 46002. The Linux command receiver
accepts commands only from CMD_ALLOWED_IP (default 192.168.50.132). New clients
should use idempotent set-mic targets rather than the legacy swap toggle.
A route is only reported as applied after the PipeWire/Carla graph or the
matching PulseAudio loopback has been observed. Mute commands are acknowledged
only after pactl confirms the requested state.

Configuration authority
-----------------------

The mic router reads:

    ~/.config/hearth/roaring_mic_router.conf

B1_ACTIVE/B2_ACTIVE are top-level bus enable flags. CARLA_TO_B1/CARLA_TO_B2
control the direct Carla output links. An inactive bus must remain
disconnected even when its saved Carla preference is true.

The Linux sender and command receiver are installed by the matching user
systemd units in User/. Keep the active unit Environment values in sync with
the machine's private LAN setup rather than changing the tracked defaults
without a reason.

The Linux sender requests mono capture directly and selects a PulseAudio
capture fragment on each stream session from the active PipeWire quantum
(or its explicit forced quantum): 5 ms at <=256 frames, 10 ms at 512/1024
frames, and 20 ms at 2048 frames or above. Sustained live testing found that 256 frames
can xrun under this machine's load, so the restart-safe default is 512 frames
(10.67 ms at 48 kHz). The PipeWire profile lives in PipeWire/ and preserves
resample quality 10. PULSE_FRAGMENT_BYTES can override automatic selection
with an even byte count from 480 to 1920.

While streaming, the sender samples the active Scarlett capture node's
PipeWire xrun counter roughly every 5-10 seconds and waits for active-node telemetry
during startup. New xruns step the graph up from 256 to 512, then 1024 frames.
After ten clean minutes it steps down one profile at a time, but the default
minimum is 512 frames because a sustained 256-frame trial caused further
Scarlett xruns. The default minimum is 512; to explicitly opt into more
q256 trials, set ROARING_MIC_MIN_QUANTUM=256 in the user service override:

    systemctl --user edit roaring-moonlight-mic.service

    [Service]
    Environment=ROARING_MIC_MIN_QUANTUM=256

The Carla session applies the selected graph quantum after its JACK node is
created, so the 512-frame baseline survives Carla restarts. The graph change
restarts only the sender so its capture fragment is recalculated. Repeated
FFmpeg timestamp/resampler glitches also increase the
capture fragment and recycle the sender.

The Carla launcher supports the same saved native processing backend in
headless mode using Carla's --no-gui switch; a second DSP chain is not needed.
The per-user carla_mode file selects headless or patchbay. Use patchbay for
interactive editing and headless to run the single DSP engine without its UI.
ROARING_CARLA_GUI=1 also forces the interactive editor for a manual launch.

The detailed latency baseline and Rust/TypeScript migration boundary are in
docs/audio-performance.md. Any transport replacement stays isolated until it
has measured packet-jitter, XRUN, memory, and sound-quality results against the
current FFmpeg reference path.

Validation
----------

Linux:

    python -m unittest discover -s tests -v
    python -m compileall -q Bin tests
    bash -n Bin/roaring_mic_routesd.sh
    bash -n Bin/roaring_moonlight_micd.sh
    bash -n Bin/roaring_mic_bussesd.sh

Windows PowerShell:

    powershell.exe -NoProfile -File Windows\Tests\Validate-RoaringMic.ps1

The Windows validation checks PowerShell parsing, embedded C# compilation,
0/100/200% PCM gain and saturation, UDP packet filtering, duplicate-instance
behavior, and the Windows Script Host launcher using a harmless command stub.

Windows Task Scheduler
----------------------

Copy `Windows/RoaringMic.ps1`, `Windows/RoaringMic-hidden.vbs`, and
`Windows/Install-RoaringMicTask.ps1` into `%LOCALAPPDATA%\RoaringMic`.
From the same interactive Windows account, run an elevated PowerShell window:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
      "$env:LOCALAPPDATA\RoaringMic\Install-RoaringMicTask.ps1"

The installer backs up an existing task definition to a timestamped XML file,
registers an AtLogOn task in the interactive session, disables idle-stop and
execution-time limits, and configures three one-minute recovery retries. It
leaves a currently running receiver instance alone. Unless `-NoStart` is used,
it verifies that the expected RoaringMic process owns UDP port 46001.

This repository is a personal configuration snapshot. Hardware names,
network addresses, installed device drivers, and user service paths may need
adjustment on another machine.
