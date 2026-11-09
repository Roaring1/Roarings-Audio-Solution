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

The production path is 48 kHz. The live graph is currently at 512 frames, with the automatic XRUN recovery floor also persisted as 512:

- The Scarlett capture node negotiates a 128-frame ALSA period (2.67 ms).
- A 512-frame graph cycle is 10.67 ms; one mono s16le datagram aligned to that cycle is 1,024 bytes.
- A 256-frame graph (5.33 ms) was exercised but produced additional Scarlett xruns under normal machine load. The 512-frame setting was the lowest profile that passed the earlier short stability checks.
- **Current live-state audit (2026-11-09):** PipeWire's default `clock.quantum` metadata is 1,024, but `clock.force-quantum=512`; `pw-top` confirms the active Scarlett driver row is at 512 frames / 48 kHz. The persisted learned safe-quantum file is now `512`. The prior recovery to 1,024 frames was temporary; subsequent clean stability allowed the monitor to return to 512. Scarlett's current ERR count is 8, and it remained flat during the latest checks.
- Carla's plugin processing load was previously small relative to a graph cycle, and the saved rack reports roughly 5.42 ms plugin latency. Keep the DSP rack unchanged while transport experiments run.
- The live Windows WaveOut receiver has learned a high safety floor after real underruns. It remains the production fallback until the WASAPI candidate passes an on-device comparison.

The previous 2,048-byte Pulse capture block was split by FFmpeg's UDP muxer into 1,316-byte and 732-byte datagrams. The current sender keeps the Pulse input fragment graph-aware, then applies `asetnsamples=n=512:p=0,arealtime` before UDP output. This produces fixed 1,024-byte network packets, paced at about 10.67 ms, including when a future 1,024-frame graph delivers two 512-sample frames together. The production sender was restarted with this filter; a live `tcpdump` on port 46001 showed 18 consecutive 1,024-byte datagrams at 10.6-10.8 ms intervals. The latest active graph is 512 frames, so the Pulse input fragment is currently 1,024 bytes; the 2,048-byte input ceiling is reserved for the 1,024-frame graph case. No 2,048-byte UDP datagram is sent.

The Windows VB-CABLE control panel reports a fixed 48 kHz rate and a 7,168-sample maximum allocation. A trial at 1,536 samples (three 512-sample packets / 32 ms) was rolled back after the production WaveOut receiver's counters increased during concurrent testing. The 3,072-sample setting (six packets / 64 ms) has been restored and visually confirmed; the maximum remains 7,168. The extra capture reader has been stopped. Keep 3,072 until an isolated capture-quality test can establish that a smaller VB-CABLE buffer is stable without disrupting the production receiver.

The live WaveOut receiver matched the new 1,024-byte profile and reduced its arrival-jitter EWMA from about 13.4 ms to about 0.1-0.2 ms. The 1,536-sample VB-CABLE trial was rolled back to 3,072 samples. During subsequent parallel testing, the receiver's cumulative counters reached 12 underruns and 50 drops; they remained unchanged across the latest two health windows. Packet arrival stays around 10.5-10.8 ms with about 0.1 ms jitter, but the WaveOut queue remains around 64-75 ms and completion around 64-77 ms. Do not lower the learned eight-packet floor on the production stream.



### Graph-aligned packet sizing

A localhost A/B on the live 512-frame graph compared 960-byte (480-sample / 10 ms) and 1,024-byte (512-sample / 10.67 ms) FFmpeg capture fragments. Both remained stable with no capture interruption. The 1,024-byte packet represents exactly one 512-frame graph quantum, so the Windows receiver's calculated packet duration matches the sender's graph cadence instead of receiving 10 ms of audio every 10.67 ms. Measured arrival p95 was 10.867 ms for 1,024-byte packets and 10.850 ms for 960-byte packets; median cadence was effectively unchanged. The important difference was burstiness: 960-byte packets produced back-to-back arrivals as short as 0.007 ms (p05 0.011 ms), while 1,024-byte packets had a 10.256 ms minimum interval (p05 10.446 ms). Exact graph alignment removes the short-packet burst caused by a 10 ms payload arriving on a 10.67 ms graph cadence. This is the preferred 512-frame packet profile.

The graph period is not the whole end-to-end delay. Carla reports 260 samples of plugin latency (about 5.42 ms at 48 kHz). The saved rack has two visible lookahead settings: LSP Gate Mono at 0.5 ms and LSP Limiter Mono at 5 ms. Their combined configured lookahead is 5.5 ms, close to Carla's 5.42 ms report, so they are strong candidates for most of the plugin delay. This is not yet an isolated per-plugin measurement.

The LSP manual states that the limiter's lookahead buffer is added to output latency: https://lsp-plug.in/?page=manuals&section=limiter_mono. Do not lower it just to make the number smaller. A shorter lookahead can reduce the limiter's ability to catch fast peaks. The next useful experiment is an A/B using the same recorded loud speech/transient sample, first comparing the current 0.5/5 ms gate/limiter settings with a conservative 0.25/2 ms candidate. Record true peaks, clipping, loudness, and blind-listening quality. Do this on a copy of the Carla project or an isolated test graph; leave the live preset unchanged until the candidate passes.

The production WaveOut receiver currently uses its learned eight-packet floor. The Rust candidate defaults to four packets based on its own silent WASAPI run; this is a separate profile. Do not lower the production floor to match the candidate.

## Carla: one engine, not two

The saved project uses ProcessMode=2, Carla Continuous Rack. That is a single-client rack engine, not one JACK client per plugin. Running a second Carla instance would duplicate DSP load and can create conflicting JACK clients and patchbay links.

Carla's --no-gui mode can run the same saved project without opening its editor. Keep one engine only. carla_mode=patchbay is the interactive editing option; headless is the UI-free option. The live session is currently headless and is supervised by systemd. Two Carla SIGSEGV core dumps were captured during the earlier headless/duplicate-launch investigation, with the fault in Carla's standalone JACK backend. The subsequent launcher and systemd process-ownership fixes now maintain one backend, and a controlled restart restored the route with zero service restarts. That is encouraging but not a long-duration stability proof; keep monitoring the single engine and use patchbay mode as the immediate rollback if another backend crash occurs.

Do not remove LV2 plugins just because their UI is absent. First profile each plugin's CPU use and reported latency, then compare the exact same audio samples and settings for sound quality and delay.

## Where Rust fits

Rust is the preferred language for the two transport edges because they are the parts that need bounded memory, deterministic queue ownership, low-copy packet handling, and explicit timing metrics. The shared `roaring-mic-core` crate keeps PCM parsing, gain, adaptive queue math, and packet/profile rules platform-independent. It does not own the Carla DSP rack or a UI framework.

### Windows receiver candidate

The production receiver remains the PowerShell/C# WaveOut implementation. The Rust WASAPI candidate, its actual laptop test results, and its rollout gate are recorded in the dedicated section below. The Rust executable remains separate from the installed WaveOut task.

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

A separate Windows-only Rust executable lives under `crates/roaring-mic-windows`. It now has a silent-by-default UDP-to-WASAPI bridge and an independent `--udp-probe` mode. The production PowerShell/C# WaveOut receiver remains installed and continues to own UDP 46001. The Rust candidate has only been exercised on isolated UDP 46003 and has never replaced the audible route.

Implementation:

- `wasapi` / IAudioClient3, event-driven shared-mode rendering at 128 frames. The laptop's actual engine buffer at this request is 280 frames (5.83 ms); the period itself is 2.67 ms.
- A 48 kHz stereo-float WASAPI mix format fed from the existing mono S16LE wire protocol.
- `rtrb` bounded SPSC sample queue, 4 KiB OS UDP receive buffer, exact source-IP allow-list, strict raw PCM validation, and packet-size locking per session.
- MMCSS Pro Audio scheduling, Audio fallback, then restored AboveNormal priority if MMCSS is unavailable.
- Neutral Windows `Other` stream category to avoid communications ducking.
- Adaptive re-prime after an actual output underrun. The safe floor increases by one packet at most every five seconds. The queue ceiling grows with the learned floor but still discards old samples rather than allowing stale audio to build up.
- `--udp --silent` submits silence to the shared CABLE Input render endpoint. Real microphone PCM reaches that endpoint only when `--render` is explicitly passed. The existing WaveOut task remained the only production path carrying microphone audio during the parallel tests.

Measured on the laptop at 48 kHz, 128-frame WASAPI period, 280-frame engine buffer, with 1,024-byte / 512-sample UDP packets:

| Rust run | Duration | Accepted packets | Output underruns | Final floor | Queue drops | Result |
|---|---:|---:|---:|---:|---:|---|
| Two-packet start | 30 s | 2,673 | 2 | 4 | 0 | Raised itself to four |
| Three-packet start | 60 s | 5,627 | 2 | 5 | 0 | Raised itself to five |
| Four-packet start | 60 s | 5,630 | 0 | 4 | 0 | Clean silent run |

The four-packet run also had zero rejected sources, malformed packets, packet-size changes, and WASAPI event timeouts. It discarded 360 stale samples (7.5 ms) to bound queue age; maximum observed queue was 2,304 samples (48 ms), maximum packet arrival interval 27.8 ms, and maximum WASAPI event interval 11.9 ms. The four-packet candidate floor is now the default. Two- and three-packet tests demonstrate why lower settings are not the default on this connection.

The standalone Rust UDP probe independently accepted `2,556/2,556` 1,024-byte packets over 45 seconds, with zero source or PCM rejects and an observed maximum arrival gap of 11.7 ms. That separates the transport path from the WASAPI renderer and confirms the packet parser/firewall route works.

These are synthetic/silent transport and render tests, not an acoustic end-to-end microphone latency measurement. They do not prove real-audio quality through VB-CABLE. The candidate still needs a controlled, short real-audio handover with an immediate WaveOut rollback, followed by a longer quality soak, before it can replace WaveOut. Do not lower the production WaveOut floor or alter the current cable buffer to accelerate this work.

### Windows endpoint measurements

The laptop's IAudioClient3 shared-mode capabilities at 48 kHz:

| Endpoint | Minimum | Default |
|---|---:|---:|
| CABLE Input (render) | 128 frames / 2.67 ms | 480 frames / 10 ms |
| CABLE Output (capture) | 480 frames / 10 ms | 480 frames / 10 ms |

A 256-frame render request produced a 562-frame engine buffer (11.71 ms), so it was not lower latency in practice than the 128-frame request. These are driver/endpoint values, not acoustic measurements.

### Build checks

The repository now has a Rust workflow that runs Linux core tests, Windows-target type-checking, native Windows MSVC builds, Clippy with warnings denied, and the existing PowerShell receiver regression suite. The Windows build artifact is kept separate from the installed receiver.
