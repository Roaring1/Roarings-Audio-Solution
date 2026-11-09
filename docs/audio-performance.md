# Audio performance baseline and migration plan

## Current production signal path

The current B1 path remains:

1. SM7B / Scarlett Solo capture.
2. sm7b_mono and the saved Carla processing rack.
3. Carla output to mic_b1 stereo playback.
4. FFmpeg captures b1_mic as 48 kHz mono signed 16-bit PCM.
5. UDP port 46001 to the Windows receiver.
6. Windows validates source and packet shape, adaptively buffers, and writes PCM to VB-Audio Cable with WaveOut.

Keep this path intact while evaluating replacements. The sound-processing chain is not being rewritten as part of transport optimization.

## Measured operating profile

The previously validated low-latency profile was 48 kHz with a 512-frame PipeWire graph quantum. That is a historical test result, not the current persisted production profile:

- The Scarlett capture node negotiates a 128-frame ALSA period (2.67 ms).
- A 512-frame graph cycle is 10.67 ms; one mono s16le datagram aligned to that cycle is 1,024 bytes.
- A 256-frame graph (5.33 ms) was exercised but produced additional Scarlett xruns under normal machine load. The 512-frame setting was the lowest profile that passed the earlier short stability checks.
- **Current live-state audit (2026-11-09):** PipeWire's default `clock.quantum` metadata is 1,024, but `clock.force-quantum=512`; `pw-top` confirms the active Scarlett and Carla driver rows are at 512 frames / 48 kHz. The persisted learned safe-quantum file contains `1024`, so the next supervised Carla restart will reapply that conservative floor. The current graph is still 512 frames until that restart. A 32-second 1,024-byte-fragment trial did not increase Scarlett ERR (7), Carla ERR (0), or B1 ERR (1).
- Carla's plugin processing load was previously small relative to a graph cycle, and the saved rack reports roughly 5.42 ms plugin latency. Keep the DSP rack unchanged while transport experiments run.
- The live Windows WaveOut receiver has learned a high safety floor after real underruns. It remains the production fallback until the WASAPI candidate passes an on-device comparison.

The previous 2,048-byte capture block was being split by FFmpeg's `pkt_size=1316` UDP muxer into 1,316-byte and 732-byte datagrams. The Windows receiver consequently saw alternating packet sizes and near-back-to-back arrivals, which inflated its learned safety floor. The deployed sender now caps Pulse fragments at 1,024 bytes. A local loopback A/B measured one 1,024-byte datagram every 10.67 ms (p95 10.90 ms), while the 2,048-byte block produced the 1,316+732 split and 21.48 ms p95 inter-packet gaps. A live `tcpdump` on the PC-to-laptop interface confirmed consecutive 1,024-byte datagrams at 10.6-10.8 ms intervals. This uses the currently active 512-frame graph without changing the Carla rack or persisted safety floor.

The Windows VB-CABLE control panel reports a fixed 48 kHz rate and a 7,168-sample maximum allocation. A trial at 1,536 samples (three 512-sample packets / 32 ms) was rolled back after the production WaveOut receiver's learned floor rose from four to five packets and its underrun/drop counters increased from 2/3 to 3/7 while an additional CABLE Output capture reader was active. The known-good 3,072-sample setting (six packets / 64 ms) has been restored and visually confirmed. The extra capture reader has been stopped. Keep the 7,168 maximum unchanged. Do not retry 1,536 until the Rust WASAPI path can be tested independently and the cable's pull-loss rate is measured without degrading the production receiver.

The live WaveOut receiver matched the new 1,024-byte profile and lowered its learned floor from 8 to 4 after two real startup underruns at the attempted two-packet floor. Its arrival-jitter EWMA dropped from about 13.4 ms to about 0.1-0.2 ms, and subsequent health snapshots showed no new underrun/drop increments. The WaveOut completion/queue remains roughly 68-74 ms (about 64-75 ms queued), so the WASAPI candidate remains the likely path to lower Windows rendering latency.



### Graph-aligned packet sizing

A localhost A/B on the live 512-frame graph compared 960-byte (480-sample / 10 ms) and 1,024-byte (512-sample / 10.67 ms) FFmpeg capture fragments. Both remained stable with no capture interruption. The 1,024-byte packet represents exactly one 512-frame graph quantum, so the Windows receiver's calculated packet duration matches the sender's graph cadence instead of receiving 10 ms of audio every 10.67 ms. Measured arrival p95 was 10.867 ms for 1,024-byte packets and 10.850 ms for 960-byte packets; median cadence was effectively unchanged. The important difference was burstiness: 960-byte packets produced back-to-back arrivals as short as 0.007 ms (p05 0.011 ms), while 1,024-byte packets had a 10.256 ms minimum interval (p05 10.446 ms). Exact graph alignment removes the short-packet burst caused by a 10 ms payload arriving on a 10.67 ms graph cadence. This is the preferred 512-frame packet profile.

The graph period is not the whole end-to-end delay. Carla reports 260 samples of plugin latency (about 5.42 ms at 48 kHz). The saved rack has two visible lookahead settings: LSP Gate Mono at 0.5 ms and LSP Limiter Mono at 5 ms. Their combined configured lookahead is 5.5 ms, close to Carla's 5.42 ms report, so they are strong candidates for most of the plugin delay. This is not yet an isolated per-plugin measurement.

The LSP manual states that the limiter's lookahead buffer is added to output latency: https://lsp-plug.in/?page=manuals&section=limiter_mono. Do not lower it just to make the number smaller. A shorter lookahead can reduce the limiter's ability to catch fast peaks. The next useful experiment is an A/B using the same recorded loud speech/transient sample, first comparing the current 0.5/5 ms gate/limiter settings with a conservative 0.25/2 ms candidate. Record true peaks, clipping, loudness, and blind-listening quality. Do this on a copy of the Carla project or an isolated test graph; leave the live preset unchanged until the candidate passes.

The Windows receiver deliberately holds two packets initially to preserve quality. That queue and the plugin lookahead should be measured separately before reducing their safety margin.

## Carla: one engine, not two

The saved project uses ProcessMode=2, Carla Continuous Rack. That is a single-client rack engine, not one JACK client per plugin. Running a second Carla instance would duplicate DSP load and can create conflicting JACK clients and patchbay links.

Carla's --no-gui mode can run the same saved project without opening its editor. Keep one engine only. carla_mode=patchbay is the interactive editing option; headless is the UI-free option. The live session is currently headless and is supervised by systemd. Two Carla SIGSEGV core dumps were captured during the earlier headless/duplicate-launch investigation, with the fault in Carla's standalone JACK backend. The subsequent launcher and systemd process-ownership fixes now maintain one backend, and a controlled restart restored the route with zero service restarts. That is encouraging but not a long-duration stability proof; keep monitoring the single engine and use patchbay mode as the immediate rollback if another backend crash occurs.

Do not remove LV2 plugins just because their UI is absent. First profile each plugin's CPU use and reported latency, then compare the exact same audio samples and settings for sound quality and delay.

## Where Rust fits

Rust is the preferred language for the two transport edges because they are the parts that need bounded memory, deterministic queue ownership, low-copy packet handling, and explicit timing metrics. The shared `roaring-mic-core` crate keeps PCM parsing, gain, adaptive queue math, and packet/profile rules platform-independent. It does not own the Carla DSP rack or a UI framework.

### Windows receiver candidate

The current production receiver remains the PowerShell host with its embedded C# WaveOut engine. It is the known-good rollback. The Rust candidate uses:

- `wasapi` and IAudioClient3 for event-driven shared-mode rendering. It does not take exclusive control of the audio endpoint.
- `rtrb` for a bounded SPSC sample queue between a normal UDP thread and the render thread.
- A 48 kHz stereo float WASAPI mix format, fed from the existing mono S16LE UDP wire format.
- An exact sender-IP allow-list, strict datagram validation, MMCSS Pro Audio scheduling, and bounded event/queue/drop diagnostics.
- Automatic re-priming with a one-step safe-floor increase after an actual output underrun. The initial floor is two packets; one packet is not the default.

On the laptop, CABLE Input reports a 128-frame minimum shared period. The actual shared engine buffer at that request was 280 frames (5.83 ms). A parallel silent-output run received 2,816 packets in 30 seconds with no rejects, queue drops, event timeouts, or underrun frames at 128 frames/two packets. The one-packet run recorded one 128-frame underrun; the 256-frame/two-packet run was also clean but reported a 562-frame (11.71 ms) engine buffer. This is a measured pipeline result, not an acoustic end-to-end latency measurement. The Rust executable is not deployed and the WaveOut route remains active.

The Windows build CI must compile the real MSVC binary and run the existing receiver tests before an artifact can be considered for laptop testing. The first laptop run should use `--silent` on an isolated UDP port while the WaveOut production receiver continues to provide the audible signal. Only after packet, queue, continuity, and long-duration tests pass should a controlled handover be attempted.

### Linux capture candidate

The Linux transport remains FFmpeg/PulseAudio-compatible capture because it is reliable and keeps the Scarlett/Carla path unchanged. A separate native PipeWire Rust feasibility prototype exists outside the repository at `/tmp/roaring-pw-rust-transport`. It uses the `pipewire` and `rtrb` crates, captures the already-processed B1 monitor node, downmixes float audio to mono S16LE, and sends the existing UDP datagrams from a non-real-time worker. The PipeWire callback only reads the mapped audio buffer and pushes samples into a bounded SPSC ring.

That prototype proves the PipeWire API and basic data path, not production readiness. It still needs stronger format-change and stream-state handling, an interruptible sender worker rather than repeated 250-microsecond polling, complete shutdown cleanup on every error, xrun/queue-age telemetry, and committed automated tests. It must also report the actual PipeWire quantum and callback frame distribution instead of assuming the requested `node.latency` was honored. The FFmpeg sender stays installed and remains the A/B reference until this work is brought into the repository and passes sustained tests.

A separate Pulse-based Rust sender feasibility test produced similar packet cadence to FFmpeg in short localhost runs. It did not show a meaningful latency improvement, so the more promising Linux direction is a native PipeWire client, not another Pulse wrapper.

### Language and Carla boundary

- Rust: packet transport, bounded queues, adaptive buffering, format conversion, timing and health metrics.
- C++/WDK: only if a purpose-built Windows capture driver is eventually justified. A signed kernel driver is a substantially larger project and is not needed to prove the WASAPI renderer.
- TypeScript: optional configuration and diagnostics UI only. It is not part of the audio callback or packet pump.
- Carla: keep one DSP engine. A second Carla instance duplicates the rack, DSP work, and routing complexity. `--no-gui` removes the editor, not the processing engine. The previous headless standalone backend had SIGSEGV incidents, so continue supervising the single instance and compare PipeWire filter-chain only as an isolated reproduction of the saved LV2 rack. Do not change the live preset as part of transport migration.

## Acceptance criteria for any replacement

Keep a replacement off the live route until it passes all of these against the current FFmpeg baseline:

1. Identical 48 kHz mono PCM content and no unexpected gain, channel, or sample-format changes.
2. Measured packet inter-arrival average, p95, p99, and maximum under normal load and CPU contention.
3. Zero new Scarlett xruns during a sustained run, plus explicit sender-side queue/drop metrics.
4. No growing memory use, thread count, or queued-audio age.
5. Equivalent audible processing quality through the same Carla rack.
6. A one-command rollback to the current sender and receiver.

The objective is lower observed end-to-end latency while retaining quality, not a smaller buffer setting on paper.


## Rust WASAPI receiver candidate (not production)

A separate Windows-only Rust executable is being developed under `crates/roaring-mic-windows`. The source now contains a silent-by-default UDP-to-WASAPI bridge; the new bridge has passed Linux-side Windows-target type-check and strict Clippy but still needs a fresh native Windows CI build and live silent-UDP test. It preserves the current 48 kHz mono S16LE UDP protocol and uses:

- `wasapi` for IAudioClient3 event-driven shared-mode rendering.
- `rtrb` for a bounded single-producer/single-consumer sample ring.
- A dedicated UDP thread with an exact sender-IP allow-list and packet validation.
- MMCSS `Pro Audio` scheduling for the render thread, with `Audio` and restored AboveNormal fallbacks. The stream uses the neutral `Other` category so it does not request Communications ducking of unrelated Windows audio.
- A 4 KiB kernel UDP receive buffer and bounded SPSC queue; queue depth is capped to four packets by discarding stale samples rather than building seconds of delayed audio.
- A two-packet startup floor, automatic re-priming after actual output underruns, and one-packet safe-floor growth at most every five seconds.
- Exact sender-IP filtering and packet-size locking for each session. Variable-size 1,316+732 split datagrams are rejected instead of corrupting packet-duration estimates.
- `--udp --silent` consumes real UDP data and drives the WASAPI event loop but outputs silence. Actual microphone rendering requires an explicit `--render` argument. This permits a parallel test while the existing microphone signal remains the only audible stream.

### Windows endpoint measurements

The Windows laptop reports these IAudioClient3 shared-mode capabilities at 48 kHz:

| Endpoint | Minimum | Default |
|---|---:|---:|
| CABLE Input (render) | 128 frames / 2.67 ms | 480 frames / 10 ms |
| CABLE Output (capture) | 480 frames / 10 ms | 480 frames / 10 ms |

A WASAPI event-driven capability test on CABLE Input at 128 frames reported a 280-frame engine buffer (5.83 ms), with roughly 2.02 ms median and 2.66 ms p95 event wake intervals. An earlier isolated C# UDP-to-WASAPI probe received 2,816 packets in 30 seconds with no wrong-source packets, queue drops, event timeouts, or underrun frames using a two-packet prebuffer. A one-packet run received the same packet count but recorded one 128-frame output underrun. A 256-frame run also had zero underruns, but its engine buffer was 562 frames (11.71 ms). These were silent-output tests; they did not duplicate the live microphone into the cable. They validate the endpoint and transport, not the Rust receiver currently being built.

The Rust candidate is configured for 128-frame shared-mode rendering and a two-packet floor. One packet is not the default. The Rust source now implements the UDP bridge, but its native MSVC build and on-device silent-UDP test must pass after the latest bridge commit. The C# probe results above are reference measurements only. None of these tests is an acoustic end-to-end latency measurement. The candidate has not replaced WaveOut and must not be installed as the automatic receiver until native Windows CI, sustained silent testing, a controlled real-audio handover, and rollback all pass.

### Build checks

The repository now has a Rust workflow that runs Linux core tests, Windows-target type-checking, native Windows MSVC builds, Clippy with warnings denied, and the existing PowerShell receiver regression suite. The Windows build artifact is kept separate from the installed receiver.
