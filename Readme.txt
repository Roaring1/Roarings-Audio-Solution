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
      "PreBufPkts": 5,
      "Volume": 100
    }

Output volume is a receiver-side PCM gain from 0% to 200%. 100% is unity gain.
Values above 100% can clip; output is saturated safely to signed 16-bit PCM
and the receiver tracks clipped samples. The saved default remains 100%.

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

This repository is a personal configuration snapshot. Hardware names,
network addresses, installed device drivers, and user service paths may need
adjustment on another machine.
