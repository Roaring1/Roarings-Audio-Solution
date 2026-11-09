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

The current measured baseline is 48 kHz with a 512-frame PipeWire graph quantum:

- 512 / 48000 = 10.67 ms per graph cycle.
- The Scarlett capture node negotiates a 128-frame ALSA period (2.67 ms).
- The Linux sender selects a 960-byte mono PCM fragment (10 ms).
- Carla is in Continuous Rack mode, a single-client rack processing mode.
- Carla used about 6-8% of the observed graph-cycle processing budget during the live checks.
- The Scarlett capture-node ERR count did not increase during the latest 16-second steady-state window at 512 frames.
- The Windows receiver's auto mode starts with a two-packet floor, can grow to eight packets on late arrivals, and slowly returns toward the floor after stable traffic.
- The Windows UDP receive socket is capped at 8 KiB to prevent seconds of stale queued audio after a scheduling stall.

A 256-frame graph (5.33 ms) was exercised, but it produced additional Scarlett xruns under the machine's normal load. The safe default is therefore 512 frames. ROARING_MIC_MIN_QUANTUM=256 is an explicit opt-in for further trials, not the default. A new xrun steps the graph up (256 -> 512 -> 1024); the sender's monitor retries lower settings only after a clean interval. Carla's session applies the 512-frame graph force after its JACK node appears, so a Carla restart does not silently restore the 1024-frame default.

The graph period is not the whole end-to-end delay. Carla reports 260 samples of plugin latency (about 5.42 ms at 48 kHz). The saved rack has two visible lookahead settings: LSP Gate Mono at 0.5 ms and LSP Limiter Mono at 5 ms. Their combined configured lookahead is 5.5 ms, close to Carla's 5.42 ms report, so they are strong candidates for most of the plugin delay. This is not yet an isolated per-plugin measurement.

The LSP manual states that the limiter's lookahead buffer is added to output latency: https://lsp-plug.in/?page=manuals&section=limiter_mono. Do not lower it just to make the number smaller. A shorter lookahead can reduce the limiter's ability to catch fast peaks. The next useful experiment is an A/B using the same recorded loud speech/transient sample, first comparing the current 0.5/5 ms gate/limiter settings with a conservative 0.25/2 ms candidate. Record true peaks, clipping, loudness, and blind-listening quality. Do this on a copy of the Carla project or an isolated test graph; leave the live preset unchanged until the candidate passes.

The Windows receiver deliberately holds two packets initially to preserve quality. That queue and the plugin lookahead should be measured separately before reducing their safety margin.

## Carla: one engine, not two

The saved project uses ProcessMode=2, Carla Continuous Rack. That is a single-client rack engine, not one JACK client per plugin. Running a second Carla instance would duplicate DSP load and can create conflicting JACK clients and patchbay links.

Carla's --no-gui mode can run the same saved project without opening its editor. Keep one engine only. carla_mode=patchbay is the interactive editing option; headless is the UI-free option. The live session is currently headless, but a headless-only crash was observed during earlier overlapping launch attempts. The process guard and systemd startup helpers now prevent substring-based self-matches and duplicate launches. Continue to monitor this singleton before treating headless as fully proven over long sessions.

Do not remove LV2 plugins just because their UI is absent. First profile each plugin's CPU use and reported latency, then compare the exact same audio samples and settings for sound quality and delay.

## Where Rust fits

The most promising replacement candidate is the Linux transport edge, not the Carla DSP rack or the Windows UI:

- A Rust JACK client can read the already-processed mic_b1 monitor ports directly through PipeWire's JACK compatibility layer.
- Its real-time JACK callback should only copy a preallocated block of samples into a bounded single-producer/single-consumer ring buffer.
- A separate non-real-time worker can downmix stereo to mono, convert to s16le, form the existing 10 ms datagrams, and send UDP to port 46001.
- Ring-buffer overflow, UDP send errors, packet sequence gaps, and capture xrun counts must be explicit metrics.
- The existing FFmpeg sender remains the fallback and A/B reference until the Rust path proves equal sound quality and lower measured latency.

Never call blocking network I/O, allocate memory, wait on a mutex, or perform filesystem/logging work inside the JACK process callback. The jack crate provides JACK process handlers and audio-port slices; use a preallocated SPSC ring such as rtrb to move audio to a normal worker thread. This machine currently has Rust installed but lacks JACK development headers and cached jack/rtrb crates, so a real build and load test require those build dependencies. No unbuildable Rust dependency is part of production.

TypeScript is appropriate for a future configuration UI, diagnostics dashboard, or control surface. It is not the preferred audio callback or packet pump: garbage collection and runtime scheduling introduce jitter that is unnecessary in the real-time signal path.

## Acceptance criteria for any replacement

Keep a replacement off the live route until it passes all of these against the current FFmpeg baseline:

1. Identical 48 kHz mono PCM content and no unexpected gain, channel, or sample-format changes.
2. Measured packet inter-arrival average, p95, p99, and maximum under normal load and CPU contention.
3. Zero new Scarlett xruns during a sustained run, plus explicit sender-side queue/drop metrics.
4. No growing memory use, thread count, or queued-audio age.
5. Equivalent audible processing quality through the same Carla rack.
6. A one-command rollback to the current sender and receiver.

The objective is lower observed end-to-end latency while retaining quality, not a smaller buffer setting on paper.
