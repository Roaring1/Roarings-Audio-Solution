#Requires -Version 5.1
using namespace System.Windows.Forms
using namespace System.Drawing
using namespace System.Drawing.Drawing2D
<#
  RoaringMic.ps1  --  Moonlight mic passthrough tray companion.
  v2.5 -- Jitter buffer (no more clicking), correct PC address (Swap/Mute actually
          arrive, presence ping watches the PC not itself), unscaled flyout layout,
          and the CABLE Output endpoint is renamed live/ready/offline.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$script:Mtx = New-Object System.Threading.Mutex($false, 'Global\RoaringMicTray_v3')
$script:MtxOwned = $false
try { $script:MtxOwned = $script:Mtx.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $script:MtxOwned = $true }  # prior process was killed; we now own it
if (-not $script:MtxOwned) {
    # Scheduled-task duplicates may be non-interactive; never block on a modal dialog.
    try { $script:Mtx.Dispose() } catch {}
    exit 0
}

$AppDir  = "$env:LOCALAPPDATA\RoaringMic"
$CfgPath = "$AppDir\config.json"
$null    = New-Item $AppDir -ItemType Directory -Force -EA SilentlyContinue

$Cfg = [PSCustomObject]@{ Port = 46001; Rate = 48000; PcHost = '192.168.50.123'; PreBufMode = 'auto'; PreBufPkts = 5; SafePreBufPkts = 2; SafePreBufPeerIP = ''; SafePreBufRate = 48000; SafePreBufPacketBytes = 0; Volume = 100 }
if (Test-Path $CfgPath) {
    try {
        $j = Get-Content $CfgPath -Raw | ConvertFrom-Json
        foreach ($p in $Cfg.PSObject.Properties.Name) { if ($null -ne $j.$p) { $Cfg.$p = $j.$p } }
    } catch {}
}
try { $Cfg.Volume = [Math]::Max(0,[Math]::Min(200,[int]$Cfg.Volume)) }
catch { $Cfg.Volume = 100 }
try { $Cfg.Port = [Math]::Max(1,[Math]::Min(65535,[int]$Cfg.Port)) }
catch { $Cfg.Port = 46001 }
try { $Cfg.PreBufPkts = [Math]::Max(1,[Math]::Min(8,[int]$Cfg.PreBufPkts)) }
catch { $Cfg.PreBufPkts = 5 }
try { $Cfg.SafePreBufPkts = [Math]::Max(1,[Math]::Min(8,[int]$Cfg.SafePreBufPkts)) }
catch { $Cfg.SafePreBufPkts = 2 }
try { $Cfg.SafePreBufRate = [Math]::Max(8000,[Math]::Min(192000,[int]$Cfg.SafePreBufRate)) }
catch { $Cfg.SafePreBufRate = 48000 }
try { $Cfg.SafePreBufPacketBytes = [Math]::Max(0,[Math]::Min(8192,[int]$Cfg.SafePreBufPacketBytes)) }
catch { $Cfg.SafePreBufPacketBytes = 0 }
try {
    $parsedPc = [System.Net.IPAddress]::Parse([string]$Cfg.PcHost)
    if ($parsedPc.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw 'Expected IPv4' }
    $Cfg.PcHost = $parsedPc.ToString()
} catch { $Cfg.PcHost = '192.168.50.123' }

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;

public static class WaveRouter {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    struct WAVEOUTCAPS {
        public ushort wMid, wPid; public uint vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname;
        public uint dwFormats; public ushort wChannels, wReserved1; public uint dwSupport;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct WAVEFORMATEX {
        public ushort wFormatTag, nChannels;
        public uint nSamplesPerSec, nAvgBytesPerSec;
        public ushort nBlockAlign, wBitsPerSample, cbSize;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct WAVEHDR {
        public IntPtr lpData; public uint dwBufferLength, dwBytesRecorded;
        public IntPtr dwUser; public uint dwFlags, dwLoops; public IntPtr lpNext, reserved;
    }

    [DllImport("winmm.dll")] static extern uint waveOutGetNumDevs();
    [DllImport("winmm.dll", CharSet = CharSet.Auto)]
    static extern uint waveOutGetDevCaps(int id, ref WAVEOUTCAPS c, uint sz);
    [DllImport("winmm.dll")]
    static extern uint waveOutOpen(out IntPtr h, int id, ref WAVEFORMATEX f, IntPtr cb, IntPtr inst, uint fl);
    [DllImport("winmm.dll")] static extern uint waveOutPrepareHeader(IntPtr h, IntPtr p, uint s);
    [DllImport("winmm.dll")] static extern uint waveOutWrite(IntPtr h, IntPtr p, uint s);
    [DllImport("winmm.dll")] static extern uint waveOutUnprepareHeader(IntPtr h, IntPtr p, uint s);
    [DllImport("winmm.dll")] static extern uint waveOutReset(IntPtr h);
    [DllImport("winmm.dll")] static extern uint waveOutClose(IntPtr h);

    [DllImport("avrt.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr AvSetMmThreadCharacteristics(string taskName, ref uint taskIndex);
    [DllImport("avrt.dll", SetLastError = true)]
    static extern bool AvSetMmThreadPriority(IntPtr avrtHandle, int priority);
    [DllImport("avrt.dll", SetLastError = true)]
    static extern bool AvRevertMmThreadCharacteristics(IntPtr avrtHandle);

    const uint WHDR_DONE = 0x00000001u;
    const ushort WAVE_FORMAT_PCM = 1;

    public static volatile bool   Running      = false;
    public static volatile float  VuLevel      = 0f;
    public static volatile float  PlaybackVolume = 1f;
    public static          string LastError    = null;
    public static          string SourceIP     = "--";
    public static volatile int    PktsReceived = 0;
    public static volatile int    PktsDropped  = 0;
    public static int PktsRejected = 0;
    public static long ClippedSamples = 0;
    public static string AllowedSourceIP = null;
    public static long LastPacketTicks = 0;
    public static int GetRejectedPackets() { return Interlocked.CompareExchange(ref PktsRejected, 0, 0); }
    public static long GetClippedSamples() { return Interlocked.Read(ref ClippedSamples); }
    public static bool HasRecentPackets() {
        long t = Interlocked.Read(ref LastPacketTicks);
        return t > 0 && (DateTime.UtcNow.Ticks - t) < TimeSpan.TicksPerSecond * 2;
    }

    public static string DeviceNeedle = "CABLE";
    public static int    Port         = 46001;
    public static int    Rate         = 48000;
    public static volatile int PreBuf = 5;
    public static int ConfiguredPreBuf = 5;
    public static volatile bool AdaptiveBuffering = true;
    public static volatile float ArrivalJitterMs = 0f;
    public static volatile bool LastArrivalWasLate = false;
    public static volatile int Underruns = 0;
    public static volatile int InFlight = 0;
    public static int CompletedBuffers = 0;
    public static volatile float LastArrivalIntervalMs = 0f;
    public static volatile float LastBufferCompletionMs = 0f;
    public static volatile bool Primed = false;
    public static volatile string MmcssMode = "not-started";
    public static volatile string ActiveDeviceName = "unselected";
    private static long LastArrivalStopwatchTicks = 0;
    private static double LastPacketDurationMs = 0.0;
    private static int StableArrivalCount = 0;
    // Start at the proven two-packet baseline, then learn a per-peer safe floor from
    // actual WaveOut underruns. Persisted floors are scoped to peer, rate, and
    // packet size so a changed route/profile gets a fresh low-latency trial.
    public static volatile int MinAutoPreBuf = 2;
    public const int MaxAutoPreBuf = 8;
    public static volatile int ExpectedPacketBytes = 0;
    public static volatile int LastPacketBytes = 0;
    private static long StableFloorSinceTicks = 0;
    private static long LastFloorRaiseTicks = 0;
    private static bool PacketProfileChecked = false;

    public static bool IsSafePreBufPeerRateMatch(string savedPeer, string currentPeer,
        int savedRate, int currentRate) {
        return !String.IsNullOrWhiteSpace(savedPeer) &&
            String.Equals(savedPeer, currentPeer, StringComparison.OrdinalIgnoreCase) &&
            savedRate == currentRate;
    }

    public static bool IsSafePreBufPacketSizeMatch(int savedBytes, int currentBytes) {
        return savedBytes > 0 && currentBytes > 0 && savedBytes == currentBytes;
    }

    public static bool IsPacketArrivalLate(double intervalMs, double packetMs) {
        if (intervalMs <= 0.0 || packetMs <= 0.0) return false;
        return intervalMs > packetMs + Math.Max(2.0, packetMs * 0.25);
    }

    public static int CalculateAdaptivePreBuf(int current, double intervalMs,
        double packetMs, int min, int max) {
        if (min < 1) min = 1;
        if (max < min) max = min;
        current = Math.Max(min, Math.Min(max, current));
        if (intervalMs <= 0.0 || packetMs <= 0.0) return current;
        if (!IsPacketArrivalLate(intervalMs, packetMs)) return current;
        int needed = (int)Math.Ceiling(intervalMs / packetMs);
        // Grow only to the number of packet durations actually needed. A
        // slightly late packet must not add a redundant full packet of delay.
        return Math.Min(max, Math.Max(current, Math.Max(min, needed)));
    }

    public static int ClampSafePreBuf(int value) {
        return Math.Max(1, Math.Min(MaxAutoPreBuf, value));
    }

    public static int CalculateNextSafePreBuf(int currentFloor, int max) {
        if (max < 1) max = 1;
        currentFloor = Math.Max(1, Math.Min(max, currentFloor));
        return Math.Min(max, currentFloor + 1);
    }

    public static IntPtr EnterAudioScheduling() {
        uint taskIndex = 0;
        try {
            IntPtr h = AvSetMmThreadCharacteristics("Pro Audio", ref taskIndex);
            if (h != IntPtr.Zero) {
                AvSetMmThreadPriority(h, 1); // AVRT_PRIORITY_HIGH, not Critical.
                MmcssMode = "Pro Audio";
                return h;
            }
            taskIndex = 0;
            h = AvSetMmThreadCharacteristics("Audio", ref taskIndex);
            if (h != IntPtr.Zero) {
                AvSetMmThreadPriority(h, 1);
                MmcssMode = "Audio";
                return h;
            }
        } catch {}
        try {
            Thread.CurrentThread.Priority = ThreadPriority.AboveNormal;
            MmcssMode = "AboveNormal fallback";
        } catch {
            MmcssMode = "Normal fallback";
        }
        return IntPtr.Zero;
    }

    public static void ReleaseAudioScheduling(IntPtr handle) {
        if (handle != IntPtr.Zero) {
            try { AvRevertMmThreadCharacteristics(handle); } catch {}
        }
        MmcssMode = "stopped";
    }

    private static void ObservePacketArrival(int packetBytes) {
        long now = Stopwatch.GetTimestamp();
        double packetMs = packetBytes * 500.0 / Rate;
        LastPacketBytes = packetBytes;
        if (!PacketProfileChecked) {
            PacketProfileChecked = true;
            if (ExpectedPacketBytes > 0 && !IsSafePreBufPacketSizeMatch(ExpectedPacketBytes, packetBytes)) {
                // A new graph quantum or packet profile invalidates the old
                // connection floor. Re-learn from the conservative two-packet
                // baseline, never inherit a depth measured for another profile.
                MinAutoPreBuf = 2;
                PreBuf = 2;
                StableArrivalCount = 0;
                StableFloorSinceTicks = 0;
                LastFloorRaiseTicks = 0;
            }
        }
        long previous = Interlocked.Exchange(ref LastArrivalStopwatchTicks, now);
        if (previous > 0 && LastPacketDurationMs > 0.0) {
            double intervalMs = (now - previous) * 1000.0 / Stopwatch.Frequency;
            LastArrivalIntervalMs = (float)intervalMs;
            double deviation = Math.Abs(intervalMs - LastPacketDurationMs);
            ArrivalJitterMs = (float)(ArrivalJitterMs * 0.875 + deviation * 0.125);
            LastArrivalWasLate = IsPacketArrivalLate(intervalMs, LastPacketDurationMs);
            if (AdaptiveBuffering) {
                int next = CalculateAdaptivePreBuf(PreBuf, intervalMs,
                    LastPacketDurationMs, MinAutoPreBuf, MaxAutoPreBuf);
                if (next > PreBuf) {
                    PreBuf = next;
                    StableArrivalCount = 0;
                } else if (!LastArrivalWasLate) {
                    StableArrivalCount++;
                    if (StableArrivalCount >= 6000 && PreBuf > MinAutoPreBuf) {
                        PreBuf--;
                        StableArrivalCount = 0;
                    }
                    // Only lower a learned connection floor after ten clean
                    // wall-clock minutes, independent of packet duration.
                    // One isolated jitter spike therefore cannot permanently
                    // tax latency, but real underruns are retained.
                    if (StableFloorSinceTicks == 0) StableFloorSinceTicks = now;
                    else if (MinAutoPreBuf > 1 && now - StableFloorSinceTicks >= Stopwatch.Frequency * 600L) {
                        MinAutoPreBuf--;
                        if (PreBuf < MinAutoPreBuf) PreBuf = MinAutoPreBuf;
                        StableFloorSinceTicks = now;
                    }
                } else {
                    StableArrivalCount = 0;
                    StableFloorSinceTicks = 0;
                }
            }
        }
        LastPacketDurationMs = packetMs;
    }

    public static bool HasCableDevice() {
        uint n = waveOutGetNumDevs();
        for (int i = 0; i < (int)n; i++) {
            var c = new WAVEOUTCAPS();
            waveOutGetDevCaps(i, ref c, (uint)Marshal.SizeOf(c));
            if (c.szPname != null && c.szPname.IndexOf(DeviceNeedle, StringComparison.OrdinalIgnoreCase) >= 0)
                return true;
        }
        return false;
    }

    public static void ResetCounters() {
        PktsReceived = 0; PktsDropped = 0; PktsRejected = 0; SourceIP = "--";
        Underruns = 0; Primed = false; ArrivalJitterMs = 0f;
        LastArrivalWasLate = false;
        InFlight = 0;
        CompletedBuffers = 0;
        LastArrivalIntervalMs = 0f;
        LastBufferCompletionMs = 0f;
        LastPacketBytes = 0;
        PacketProfileChecked = false;
        Interlocked.Exchange(ref ClippedSamples, 0);
        Interlocked.Exchange(ref LastArrivalStopwatchTicks, 0);
        LastPacketDurationMs = 0.0; StableArrivalCount = 0; StableFloorSinceTicks = 0; LastFloorRaiseTicks = 0;
        PreBuf = AdaptiveBuffering
            ? MinAutoPreBuf
            : Math.Max(1, Math.Min(MaxAutoPreBuf, ConfiguredPreBuf));
    }

    public static short ScalePcmSample(short sample) {
        float gain = Math.Max(0f, Math.Min(2f, PlaybackVolume));
        int amplified = (int)Math.Round(sample * gain);
        if (amplified > short.MaxValue || amplified < short.MinValue)
            Interlocked.Increment(ref ClippedSamples);
        return (short)Math.Max(short.MinValue, Math.Min(short.MaxValue, amplified));
    }

    public static bool IsAcceptedPacket(byte[] packet, string sourceIp) {
        if (packet == null || packet.Length < 2 || (packet.Length & 1) != 0 || packet.Length > 8192) {
            Interlocked.Increment(ref PktsRejected);
            return false;
        }
        if (!String.IsNullOrEmpty(AllowedSourceIP) &&
            !String.Equals(sourceIp, AllowedSourceIP, StringComparison.OrdinalIgnoreCase)) {
            Interlocked.Increment(ref PktsRejected);
            return false;
        }
        return true;
    }

    public static void Run() {
        // Start-Recv owns the transition to Running. Do not re-arm here:
        // Stop can arrive after BeginInvoke but before this worker starts.
        if (!Running) return;
        VuLevel = 0f; LastError = null; Primed = false; Underruns = 0;
        Interlocked.Exchange(ref LastPacketTicks, 0);
        const int NBUF = MaxAutoPreBuf; const int BUFSZ = 8192;

        int devIdx = -1;
        uint numDevs = waveOutGetNumDevs();
        for (int i = 0; i < (int)numDevs; i++) {
            var c = new WAVEOUTCAPS();
            waveOutGetDevCaps(i, ref c, (uint)Marshal.SizeOf(c));
            if (c.szPname != null && c.szPname.IndexOf(DeviceNeedle, StringComparison.OrdinalIgnoreCase) >= 0)
                { devIdx = i; ActiveDeviceName = c.szPname; break; }
        }
        if (devIdx < 0) {
            LastError = "Device '" + DeviceNeedle + "' not found among " + numDevs + " waveOut devices.";
            Running = false; return;
        }

        var fmt = new WAVEFORMATEX {
            wFormatTag = WAVE_FORMAT_PCM, nChannels = 1,
            nSamplesPerSec = (uint)Rate, wBitsPerSample = 16,
            nBlockAlign = 2, nAvgBytesPerSec = (uint)(Rate * 2), cbSize = 0
        };
        IntPtr hwo;
        uint res = waveOutOpen(out hwo, devIdx, ref fmt, IntPtr.Zero, IntPtr.Zero, 0);
        if (res != 0) { LastError = "waveOutOpen failed (code=" + res + ")"; Running = false; return; }

        int hSz = Marshal.SizeOf(typeof(WAVEHDR));
        IntPtr[] dataPtrs = new IntPtr[NBUF]; IntPtr[] hdrPtrs = new IntPtr[NBUF]; bool[] busy = new bool[NBUF];
        long[] writeTicks = new long[NBUF];
        UdpClient udp = null;
        var hold = new System.Collections.Generic.Queue<byte[]>();
        int nativeFailureStreak = 0;
        IntPtr mmcssHandle = EnterAudioScheduling();
        try {
            for (int i = 0; i < NBUF; i++) {
                dataPtrs[i] = Marshal.AllocHGlobal(BUFSZ);
                hdrPtrs[i] = Marshal.AllocHGlobal(hSz);
            }
            udp = new UdpClient(Port);
            // Keep the kernel from accumulating seconds of stale microphone
            // audio if this worker is descheduled. At 48 kHz mono s16le, 8 KiB
            // is about 85 ms; the adaptive WaveOut queue handles short jitter.
            udp.Client.ReceiveBufferSize = 8192;
            udp.Client.ReceiveTimeout = 500;
            var ep = new IPEndPoint(IPAddress.Any, 0);
            while (Running) {
                byte[] pkt;
                try { pkt = udp.Receive(ref ep); }
                catch (SocketException) {
                    if (LastPacketTicks > 0 && DateTime.UtcNow.Ticks - Interlocked.Read(ref LastPacketTicks) > TimeSpan.TicksPerSecond)
                        VuLevel = 0f;
                    continue;
                }
                // Only accept well-formed 16-bit PCM from the configured PC.
                // The UDP socket is bound on all interfaces, so source filtering
                // is required to prevent unrelated LAN traffic feeding the mic.
                if (!IsAcceptedPacket(pkt, ep.Address.ToString())) continue;

                SourceIP = ep.Address.ToString();
                Interlocked.Exchange(ref LastPacketTicks, DateTime.UtcNow.Ticks);
                ObservePacketArrival(pkt.Length);
                PktsReceived++;

                float sumSq = 0f; int nSamples = pkt.Length / 2;
                for (int s = 0; s < nSamples; s++) {
                    float f = (short)(pkt[s*2] | (pkt[s*2+1] << 8)) / 32768f;
                    sumSq += f * f;
                }
                VuLevel = (float)Math.Sqrt(sumSq / nSamples);

                // Jitter buffer. Writing each datagram straight to the device leaves
                // waveOut with nothing queued between packets, so one late or
                // reordered datagram is an audible click -- which is what "skipping"
                // and "interlaced" sound like. A 2.5G link does not prevent this:
                // the gap is scheduling jitter at both ends, not bandwidth.
                // Hold PreBuf packets before the first write, then keep the device
                // topped up, and re-prime whenever its queue runs dry.
                hold.Enqueue(pkt);

                int inFlight = 0;
                for (int i = 0; i < NBUF; i++) {
                    if (!busy[i]) continue;
                    var hck = (WAVEHDR)Marshal.PtrToStructure(hdrPtrs[i], typeof(WAVEHDR));
                    if ((hck.dwFlags & WHDR_DONE) != 0) {
                        long writtenAt = writeTicks[i];
                        if (writtenAt > 0) {
                            double completionMs = (Stopwatch.GetTimestamp() - writtenAt) * 1000.0 / Stopwatch.Frequency;
                            LastBufferCompletionMs = (float)(LastBufferCompletionMs * 0.875 + completionMs * 0.125);
                            Interlocked.Increment(ref CompletedBuffers);
                            writeTicks[i] = 0;
                        }
                        waveOutUnprepareHeader(hwo, hdrPtrs[i], (uint)hSz); busy[i] = false;
                    } else { inFlight++; }
                }
                // A packet-sized WaveOut buffer normally completes just as
                // the next on-time datagram arrives. That is not an underrun:
                // keep the stream primed and immediately queue the new packet.
                // Only re-prime and grow the buffer when the measured arrival
                // gap exceeds one packet duration plus the scheduling tolerance.
                InFlight = inFlight;
                if (Primed && inFlight == 0 && LastArrivalWasLate) {
                    Primed = false;
                    Underruns++;
                    // ObservePacketArrival already made the single bounded
                    // prebuffer increase for this late packet. Raise the
                    // persistent floor by one step per actual underrun; a single
                    // transient gap must not pin the connection at the queue cap.
                    if (AdaptiveBuffering) {
                        long now = Stopwatch.GetTimestamp();
                        int nextFloor = CalculateNextSafePreBuf(MinAutoPreBuf, MaxAutoPreBuf);
                        if (nextFloor > MinAutoPreBuf &&
                            (LastFloorRaiseTicks == 0 || now - LastFloorRaiseTicks >= Stopwatch.Frequency * 5L)) {
                            MinAutoPreBuf = nextFloor;
                            if (PreBuf < MinAutoPreBuf) PreBuf = MinAutoPreBuf;
                            LastFloorRaiseTicks = now;
                            StableFloorSinceTicks = 0;
                        }
                    }
                }
                if (!Primed) {
                    if (hold.Count < PreBuf) continue;
                    Primed = true;
                }

                while (hold.Count > 0) {
                    int slot = -1;
                    for (int i = 0; i < NBUF; i++) { if (!busy[i]) { slot = i; break; } }
                    if (slot < 0) { PktsDropped++; hold.Dequeue(); continue; }
                    byte[] outPkt = hold.Dequeue();
                    int len = Math.Min(outPkt.Length, BUFSZ);
                    for (int si = 0; si + 1 < len; si += 2) {
                        short sample = (short)(outPkt[si] | (outPkt[si+1] << 8));
                        Marshal.WriteInt16(dataPtrs[slot], si, ScalePcmSample(sample));
                    }
                    var hdr = new WAVEHDR { lpData = dataPtrs[slot], dwBufferLength = (uint)len };
                    Marshal.StructureToPtr(hdr, hdrPtrs[slot], false);
                    uint prepResult = waveOutPrepareHeader(hwo, hdrPtrs[slot], (uint)hSz);
                    if (prepResult != 0) {
                        PktsDropped++;
                        LastError = "waveOutPrepareHeader failed (code=" + prepResult + ")";
                        if (++nativeFailureStreak >= 32) throw new InvalidOperationException(LastError);
                        continue;
                    }
                    uint writeResult = waveOutWrite(hwo, hdrPtrs[slot], (uint)hSz);
                    if (writeResult != 0) {
                        waveOutUnprepareHeader(hwo, hdrPtrs[slot], (uint)hSz);
                        PktsDropped++;
                        LastError = "waveOutWrite failed (code=" + writeResult + ")";
                        if (++nativeFailureStreak >= 32) throw new InvalidOperationException(LastError);
                        continue;
                    }
                    nativeFailureStreak = 0;
                    writeTicks[slot] = Stopwatch.GetTimestamp();
                    busy[slot] = true;
                    inFlight++;
                    InFlight = inFlight;
                }
            }
        } catch (Exception ex) {
            LastError = ex.Message;
        } finally {
            VuLevel = 0f;
            try { if (udp != null) udp.Close(); } catch {}
            waveOutReset(hwo); InFlight = 0; Thread.Sleep(150);
            for (int i = 0; i < NBUF; i++) {
                if (busy[i] && hdrPtrs[i] != IntPtr.Zero) {
                    try { waveOutUnprepareHeader(hwo, hdrPtrs[i], (uint)hSz); } catch {}
                }
                if (dataPtrs[i] != IntPtr.Zero) Marshal.FreeHGlobal(dataPtrs[i]);
                if (hdrPtrs[i] != IntPtr.Zero) Marshal.FreeHGlobal(hdrPtrs[i]);
            }
            waveOutClose(hwo);
            ReleaseAudioScheduling(mmcssHandle);
            Running = false;
        }
    }

    public static void Stop() { Running = false; }
}
'@ -EA Stop

[WaveRouter]::PlaybackVolume = [Math]::Max(0.0,[Math]::Min(2.0,([double]$Cfg.Volume / 100.0)))
$script:CableFound = $false
function Probe-CableInput { $script:CableFound = [WaveRouter]::HasCableDevice() }
Probe-CableInput

function Test-SunshineUp {
    $svc = Get-Service 'SunshineService' -EA SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { return $true }
    return [bool](Get-Process 'sunshine' -EA SilentlyContinue)
}

$script:RecvPS = $null; $script:RecvHandle = $null
$script:IsStreaming = $false; $script:Since = $null
$script:RestartPending = $false
$script:RecvRetryAt = [datetime]::MinValue

function Start-Recv {
    # Do not overlap a new receiver with a worker that is still unwinding.
    if ([WaveRouter]::Running -or $script:RecvPS) { return }
    # Re-probe on every start/retry so unplug/replug and delayed device init
    # recover without requiring the user to restart the tray app.
    Probe-CableInput
    if (-not $script:CableFound) {
        $script:IsStreaming = $true
        $script:RecvRetryAt = [datetime]::Now.AddSeconds(5)
        Set-TrayState 'error'
        return
    }
    try {
        [WaveRouter]::DeviceNeedle = 'CABLE'; [WaveRouter]::Port = $Cfg.Port; [WaveRouter]::Rate = $Cfg.Rate
        [WaveRouter]::AdaptiveBuffering = ([string]$Cfg.PreBufMode -ne 'manual')
        [WaveRouter]::ConfiguredPreBuf = [int]$Cfg.PreBufPkts
        [WaveRouter]::AllowedSourceIP = [string]$Cfg.PcHost
        $profileMatches = [WaveRouter]::IsSafePreBufPeerRateMatch([string]$Cfg.SafePreBufPeerIP, [string]$Cfg.PcHost, [int]$Cfg.SafePreBufRate, [int]$Cfg.Rate)
        [WaveRouter]::MinAutoPreBuf = if ($profileMatches) { [WaveRouter]::ClampSafePreBuf([int]$Cfg.SafePreBufPkts) } else { 2 }
        [WaveRouter]::ExpectedPacketBytes = if ($profileMatches) { [int]$Cfg.SafePreBufPacketBytes } else { 0 }
        [WaveRouter]::ResetCounters()
        $script:AudioThreadDiagLogged = $false
$script:ReceiverHealthLogAt = [datetime]::MinValue
        Write-ReceiverHealthDiagnostic "profile-loaded peer=$($Cfg.PcHost) rate=$($Cfg.Rate) expectedPacketBytes=$([WaveRouter]::ExpectedPacketBytes) safeFloor=$([WaveRouter]::MinAutoPreBuf) matched=$profileMatches"
        # Arm before dispatch so an immediate Stop cannot be overwritten by
        # Run() starting later on the worker thread.
        [WaveRouter]::Running = $true
        $ps = [System.Management.Automation.PowerShell]::Create()
        [void]$ps.AddScript('[WaveRouter]::Run()')
        $handle = $ps.BeginInvoke()
        $script:RecvPS = $ps; $script:RecvHandle = $handle
        $script:RecvRetryAt = [datetime]::MinValue
        $script:Since = [datetime]::Now; $script:IsStreaming = $true
        Set-TrayState 'streaming'
    } catch {
        [WaveRouter]::Running = $false
        $script:IsStreaming = $true
        $script:RecvRetryAt = [datetime]::Now.AddSeconds(3)
        [WaveRouter]::LastError = $_.Exception.Message
        Set-TrayState 'error'
    }
}

function Stop-Recv {
    $script:IsStreaming = $false
    [WaveRouter]::Stop()
    $script:Since = $null
}

function Complete-RecvWorker {
    if (-not $script:RecvPS -or -not $script:RecvHandle -or -not $script:RecvHandle.IsCompleted) { return }
    try { $null = $script:RecvPS.EndInvoke($script:RecvHandle) }
    catch { [WaveRouter]::LastError = $_.Exception.Message }
    try { $script:RecvPS.Dispose() } catch {}
    $script:RecvPS = $null
    $script:RecvHandle = $null

    if ($script:RestartPending) {
        $script:RestartPending = $false
        Start-Recv
        return
    }

    # Retry unexpected worker exits after a short quiet period, not in a tight loop.
    if ($script:IsStreaming -and $script:NetworkOk) {
        if ($script:RecvRetryAt -eq [datetime]::MinValue) {
            $script:RecvRetryAt = [datetime]::Now.AddSeconds(3)
        } elseif ([datetime]::Now -ge $script:RecvRetryAt) {
            $script:RecvRetryAt = [datetime]::MinValue
            Start-Recv
        }
    } elseif (-not $script:IsStreaming) {
        $script:Since = $null
    }
}

function Request-RestartRecv {
    $script:RestartPending = $true
    Stop-Recv
    # If there is no worker, the request can be fulfilled immediately.
    if (-not $script:RecvPS -and -not [WaveRouter]::Running) {
        $script:RestartPending = $false
        Start-Recv
    }
}

function Get-Uptime {
    if (-not $script:Since) { return '--' }
    $s = [int]([datetime]::Now - $script:Since).TotalSeconds
    if ($s -lt 60)   { return "${s}s" }
    if ($s -lt 3600) { return "$([int]($s/60))m $($s%60)s" }
    return "$([int]($s/3600))h $([int](($s%3600)/60))m"
}

function Get-AccentColor {
    try {
        $v = Get-ItemPropertyValue 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' 'AccentColor' -EA Stop
        $r = ($v -shr 16) -band 0xFF; $g = ($v -shr 8) -band 0xFF; $b = $v -band 0xFF
        if (($r + $g + $b) -lt 90) { return [Color]::FromArgb(255,0,99,177) }
        return [Color]::FromArgb(255,$r,$g,$b)
    } catch { return [Color]::FromArgb(255,0,99,177) }
}
$Accent     = Get-AccentColor
$AccentDark = [Color]::FromArgb(255,[Math]::Max(0,$Accent.R-36),[Math]::Max(0,$Accent.G-36),[Math]::Max(0,$Accent.B-36))
$ColorOk    = [Color]::FromArgb(255,0,140,60)
$ColorWarn  = [Color]::FromArgb(255,185,100,0)
$ColorErr   = [Color]::FromArgb(255,176,32,24)

try {
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class Dwm {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int sz);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    public const int DWMWCP_ROUND = 2;
}
'@ -EA SilentlyContinue
} catch {}
function Set-RoundCorners([IntPtr]$h) {
    try { $v = [Dwm]::DWMWCP_ROUND; [Dwm]::DwmSetWindowAttribute($h,[Dwm]::DWMWA_WINDOW_CORNER_PREFERENCE,[ref]$v,4)|Out-Null } catch {}
}

function New-TrayIcon([Color]$bg) {
    $bmp = New-Object Bitmap(16,16)
    $g = [Graphics]::FromImage($bmp)
    $g.SmoothingMode = [SmoothingMode]::AntiAlias
    $g.Clear([Color]::Transparent)
    $brush = New-Object SolidBrush($bg)
    $g.FillEllipse($brush,0,0,15,15)
    $brush.Dispose()
    $font = $null; $fmt = $null
    try {
        $font = New-Object Font('Segoe MDL2 Assets',8,[FontStyle]::Regular,[GraphicsUnit]::Point)
        $fmt = New-Object StringFormat
        $fmt.Alignment = $fmt.LineAlignment = [StringAlignment]::Center
        $g.DrawString([char]0xE720,$font,[Brushes]::White,[RectangleF]::new(0,0.5,15,15),$fmt)
    } catch {
        $g.FillEllipse([Brushes]::White,5,5,5,5)
    } finally {
        if ($font) { $font.Dispose() }
        if ($fmt) { $fmt.Dispose() }
    }
    $g.Dispose()
    $hIcon = $bmp.GetHicon()
    try {
        $raw = [Icon]::FromHandle($hIcon)
        return [Icon]$raw.Clone()
    } finally {
        [Dwm]::DestroyIcon($hIcon) | Out-Null
        $bmp.Dispose()
    }
}

$Icons = @{
    idle      = New-TrayIcon ([Color]::FromArgb(255,90,90,90))
    streaming = New-TrayIcon $Accent
    error     = New-TrayIcon $ColorErr
}
$Tray = New-Object NotifyIcon; $Tray.Icon = $Icons['idle']; $Tray.Text = 'Roaring Mic -- waiting'; $Tray.Visible = $true
$script:State = 'idle'

function Set-TrayState([string]$s) {
    $script:State = $s; $Tray.Icon = if ($Icons.ContainsKey($s)) { $Icons[$s] } else { $Icons['idle'] }
    switch ($s) {
        'streaming' { $Tray.Text = "Roaring Mic  -  $script:MicSource  -  :$($Cfg.Port)" }
        'error'     { $Tray.Text = 'Roaring Mic -- error (click for details)' }
        default     { $Tray.Text = 'Roaring Mic -- waiting for Sunshine' }
    }
}

$script:VuLevel = 0.0; $script:VuTarget = 0.0; $script:VuPeak = 0.0; $script:VuPeakAge = 0

function Step-Vu {
    if ([WaveRouter]::Running) {
        $raw = [WaveRouter]::VuLevel
        if ($raw -gt 0.000001) {
            $db = 20.0 * [Math]::Log10([double]$raw)
            $script:VuTarget = [Math]::Max(0.0,[Math]::Min(1.0,($db+60.0)/60.0))
        } else { $script:VuTarget = 0.0 }
        $script:VuLevel = $script:VuLevel * 0.60 + $script:VuTarget * 0.40
    } else {
        $script:VuLevel *= 0.72; $script:VuTarget = 0.0
    }
    if ($script:VuLevel -gt $script:VuPeak) {
        $script:VuPeak = $script:VuLevel; $script:VuPeakAge = 0
    } else {
        $script:VuPeakAge++
        if ($script:VuPeakAge -gt 14) { $script:VuPeak -= 0.018 }
    }
    $script:VuPeak = [Math]::Max(0.0,$script:VuPeak)
}

$script:Flyout    = $null
$script:VuPanel   = $null
$script:StatsLbl  = $null
$script:Labels    = @{}
$script:LastPkts  = 0
$script:MicSource = 'Syncing...'
$script:MicMuted  = $false
$script:MuteKnown  = $false
$script:RouteKnown = $false
$script:SwapRetryReady = $false
$script:MuteBtn   = $null
$script:SwapBtn   = $null
$script:CmdPending = $false
$script:CmdName = ''
$script:CmdRunspace = $null
$script:StatusPollDue = [DateTime]::Now.AddMilliseconds(500)
$script:SwapTarget = ''
$script:StatusPollCount = 0
$script:CmdPowerShell = $null
$script:CmdHandle = $null
$script:VolumeBar = $null
$script:VolumeLbl = $null
function Save-ReceiverConfig {
    $tmp = "$CfgPath.tmp"
    try {
        $json = $Cfg | ConvertTo-Json -Depth 4
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmp,$json,$utf8)
        # Same-directory move on the same volume. Move-Item -Force uses
        # the Windows rename/replace path and works on Windows PowerShell 5.1;
        # the three-argument File.Replace overload is not reliable there.
        $null = Move-Item -LiteralPath $tmp -Destination $CfgPath -Force -ErrorAction Stop
        return $true
    } catch {
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
        $Tray.BalloonTipTitle = 'Roaring Mic settings'
        $Tray.BalloonTipText = "Could not save receiver settings: $($_.Exception.Message)"
        $Tray.ShowBalloonTip(2500)
        return $false
    }
}

$script:SafeProfileSaveRetryAt = [datetime]::MinValue
$script:SafeProfileDiagAt = [datetime]::MinValue
$script:AudioThreadDiagLogged = $false
$script:SafeProfileDiagPath = "$AppDir\receiver-health.log"
function Write-ReceiverHealthDiagnostic([string]$Message) {
    try {
        $line = "$(Get-Date -Format o) $Message" + [Environment]::NewLine
        [System.IO.File]::AppendAllText($script:SafeProfileDiagPath,$line)
    } catch {}
}
function Save-LearnedSafeBufferProfile {
    if (-not [WaveRouter]::AdaptiveBuffering) { return }
    if (-not [WaveRouter]::HasRecentPackets()) {
        if ([datetime]::Now -ge $script:SafeProfileDiagAt) {
            Write-ReceiverHealthDiagnostic "no-recent-packets running=$([WaveRouter]::Running) source=$([WaveRouter]::SourceIP) received=$([WaveRouter]::PktsReceived) rejected=$([WaveRouter]::GetRejectedPackets()) lastTicks=$([WaveRouter]::LastPacketTicks)"
            $script:SafeProfileDiagAt = [datetime]::Now.AddSeconds(30)
        }
        return
    }
    if (-not $script:AudioThreadDiagLogged) {
        Write-ReceiverHealthDiagnostic "receiver-active device=$([WaveRouter]::ActiveDeviceName) mmcss=$([WaveRouter]::MmcssMode) packetBytes=$([WaveRouter]::LastPacketBytes) arrivalMs=$([Math]::Round([WaveRouter]::LastArrivalIntervalMs,2)) doneMs=$([Math]::Round([WaveRouter]::LastBufferCompletionMs,2)) safeFloor=$([WaveRouter]::MinAutoPreBuf) currentBuffer=$([WaveRouter]::PreBuf) inFlight=$([WaveRouter]::InFlight) jitterMs=$([WaveRouter]::ArrivalJitterMs)"
        $script:AudioThreadDiagLogged = $true
    }
    if ([datetime]::Now -ge $script:ReceiverHealthLogAt) {
        $packetMs = [WaveRouter]::LastPacketBytes * 500.0 / [WaveRouter]::Rate
        $queueMs = [WaveRouter]::InFlight * $packetMs
        Write-ReceiverHealthDiagnostic "receiver-health device=$([WaveRouter]::ActiveDeviceName) mmcss=$([WaveRouter]::MmcssMode) safeFloor=$([WaveRouter]::MinAutoPreBuf) currentBuffer=$([WaveRouter]::PreBuf) inFlight=$([WaveRouter]::InFlight) queueMs=$([Math]::Round($queueMs,2)) arrivalMs=$([Math]::Round([WaveRouter]::LastArrivalIntervalMs,2)) doneMs=$([Math]::Round([WaveRouter]::LastBufferCompletionMs,2)) completed=$([WaveRouter]::CompletedBuffers) underruns=$([WaveRouter]::Underruns) dropped=$([WaveRouter]::PktsDropped) rejected=$([WaveRouter]::GetRejectedPackets()) jitterMs=$([WaveRouter]::ArrivalJitterMs)"
        $script:ReceiverHealthLogAt = [datetime]::Now.AddSeconds(30)
    }
    if ([datetime]::Now -lt $script:SafeProfileSaveRetryAt) { return }

    $packetBytes = [WaveRouter]::LastPacketBytes
    $safeFloor = [WaveRouter]::MinAutoPreBuf
    if ($packetBytes -le 0 -or $safeFloor -lt 1) { return }
    if ($Cfg.SafePreBufPkts -eq $safeFloor -and $Cfg.SafePreBufPeerIP -eq $Cfg.PcHost -and
        $Cfg.SafePreBufRate -eq $Cfg.Rate -and $Cfg.SafePreBufPacketBytes -eq $packetBytes) { return }

    $oldFloor = $Cfg.SafePreBufPkts
    $oldPeer = $Cfg.SafePreBufPeerIP
    $oldRate = $Cfg.SafePreBufRate
    $oldPacketBytes = $Cfg.SafePreBufPacketBytes
    $Cfg.SafePreBufPkts = $safeFloor
    $Cfg.SafePreBufPeerIP = [string]$Cfg.PcHost
    $Cfg.SafePreBufRate = [int]$Cfg.Rate
    $Cfg.SafePreBufPacketBytes = $packetBytes
    if (Save-ReceiverConfig) {
        $script:SafeProfileSaveRetryAt = [datetime]::MinValue
        Write-ReceiverHealthDiagnostic "profile-saved peer=$($Cfg.SafePreBufPeerIP) rate=$($Cfg.SafePreBufRate) packetBytes=$($Cfg.SafePreBufPacketBytes) safeFloor=$($Cfg.SafePreBufPkts) currentBuffer=$([WaveRouter]::PreBuf) underruns=$([WaveRouter]::Underruns) jitterMs=$([WaveRouter]::ArrivalJitterMs) mmcss=$([WaveRouter]::MmcssMode)"
    } else {
        Write-ReceiverHealthDiagnostic "profile-save-failed peer=$($Cfg.SafePreBufPeerIP) packetBytes=$($Cfg.SafePreBufPacketBytes)"
        # Restore the in-memory snapshot so the next timer tick retries rather
        # than assuming a profile was persisted when the atomic write failed.
        $Cfg.SafePreBufPkts = $oldFloor
        $Cfg.SafePreBufPeerIP = $oldPeer
        $Cfg.SafePreBufRate = $oldRate
        $Cfg.SafePreBufPacketBytes = $oldPacketBytes
        $script:SafeProfileSaveRetryAt = [datetime]::Now.AddSeconds(30)
    }
}

$FontUI   = New-Object Font('Segoe UI', 9)
$FontKey  = New-Object Font('Segoe UI', 8.5)
$FontVal  = New-Object Font('Segoe UI', 8.5, [FontStyle]::Bold)
$FontHead = New-Object Font('Segoe UI', 9,   [FontStyle]::Bold)
$FontTiny = New-Object Font('Segoe UI', 6.5)

function Build-Flyout {
    $FW = 310; $FH = 396
    $f = New-Object Form
    $f.FormBorderStyle = [FormBorderStyle]::None
    $f.StartPosition   = [FormStartPosition]::Manual
    $f.ShowInTaskbar   = $false
    $f.TopMost         = $true
    $f.Width           = $FW; $f.Height = $FH
    $f.BackColor       = [SystemColors]::Window
    # Every control below is positioned in exact pixels. With the default
    # AutoScaleMode=Font a scaled display moves them right without moving the
    # form edge, which is what pushed Swap off the side of the window.
    $f.AutoScaleMode   = [AutoScaleMode]::None
    $f.Font            = $FontUI

    $f.add_Paint({
        param($s,$e)
        $p = New-Object Pen([Color]::FromArgb(160,0,0,0), 1)
        $e.Graphics.DrawRectangle($p, 0, 0, $s.Width-1, $s.Height-1); $p.Dispose()
    })
    $f.add_Deactivate({ if ($script:Flyout) { $script:Flyout.Hide() } })
    $f.add_KeyDown({ param($s,$e); if ($e.KeyCode -eq [Keys]::Escape) { $script:Flyout.Hide() } })
    $f.add_Shown({ param($s,$e); Set-RoundCorners $s.Handle })

    $hdr = New-Object Panel; $hdr.Dock = [DockStyle]::Top; $hdr.Height = 40; $hdr.BackColor = $Accent

    $hLbl = New-Object Label; $hLbl.Text = '  Roaring Mic'; $hLbl.Font = $FontHead
    $hLbl.ForeColor = [Color]::White; $hLbl.AutoSize = $false
    $hLbl.Bounds = [Rectangle]::new(0,0,200,40); $hLbl.TextAlign = [ContentAlignment]::MiddleLeft
    $hdr.Controls.Add($hLbl)

    $f.Controls.Add($hdr)

    $rowDefs = @(
        @{ K='Sunshine'; V='--' }
        @{ K='Receiver'; V='--' }
        @{ K='Uptime';   V='--' }
        @{ K='Level';    V='-- dBFS' }
        @{ K='Port';     V=":$($Cfg.Port)" }
        @{ K='Device';   V='--' }
        @{ K='Source';   V="$script:MicSource (Nobara)" }
        @{ K='Remote';   V='--' }
    )
    $rowH = 24; $baseY = 48
    foreach ($i in 0..($rowDefs.Count-1)) {
        $rd = $rowDefs[$i]
        $kl = New-Object Label; $kl.AutoSize = $false
        $kl.Bounds = [Rectangle]::new(16,$baseY+$i*$rowH,72,$rowH)
        $kl.Text = $rd.K; $kl.Font = $FontKey
        $kl.ForeColor = [SystemColors]::GrayText; $kl.TextAlign = [ContentAlignment]::MiddleLeft
        $f.Controls.Add($kl)

        $vlW = if ($rd.K -eq 'Source') { $FW - 180 } else { $FW - 108 }
        $vl = New-Object Label; $vl.AutoSize = $false
        $vl.Bounds = [Rectangle]::new(92,$baseY+$i*$rowH,$vlW,$rowH)
        $vl.Text = $rd.V; $vl.Font = $FontVal
        $vl.ForeColor = [SystemColors]::ControlDarkDark; $vl.TextAlign = [ContentAlignment]::MiddleLeft
        $f.Controls.Add($vl); $script:Labels[$rd.K] = $vl
    }

    # Swap button inline with Source row (row index 6)
    $swapBtn = New-Object Button; $swapBtn.FlatStyle = [FlatStyle]::System
    $swapBtn.Text = 'Swap input'; $swapBtn.Font = New-Object Font('Segoe UI', 7.5)
    $swapBtn.Bounds = [Rectangle]::new($FW - 76, $baseY + 6*$rowH + 2, 60, 20)
    $swapBtn.Enabled = $false; $swapBtn.Text = 'Sync...'
    $swapBtn.add_Click({
        # Explicit target commands are idempotent. A retry resends the same
        # target and cannot toggle back if the original acknowledgement was late.
        if (-not $script:MuteKnown) { return }
        if ($script:SwapTarget) {
            $target = $script:SwapTarget
        } elseif (-not $script:RouteKnown) {
            $script:StatusPollDue = [DateTime]::Now
            $script:SwapBtn.Enabled = $false
            $script:SwapBtn.Text = 'Sync...'
            return
        } else {
            $current = [string]$script:MicSource
            $target = if ($current -match '^SM7B') { 'A50 boom' } else { 'SM7B' }
            $script:SwapTarget = $target
        }
        $script:StatusPollCount = 0
        $script:SwapRetryReady = $false
        if (Send-LinuxCmd ("set-mic:" + $target.ToLowerInvariant())) {
            $script:RouteKnown = $false
            $script:SwapBtn.Enabled = $false
            $script:SwapBtn.Text = 'Applying...'
        } else {
            $script:SwapBtn.Enabled = $true
            $script:SwapBtn.Text = 'Retry route'
            $script:SwapRetryReady = $true
            $script:StatusPollDue = [DateTime]::Now.AddSeconds(1)
        }
    })
    $script:SwapBtn = $swapBtn
    $f.Controls.Add($swapBtn)

    $vuTop = $baseY + $rowDefs.Count * $rowH + 4
    $vuLbl = New-Object Label; $vuLbl.AutoSize = $false
    $vuLbl.Bounds = [Rectangle]::new(16,$vuTop,40,12)
    $vuLbl.Text = 'SIGNAL'; $vuLbl.Font = $FontTiny
    $vuLbl.ForeColor = [SystemColors]::GrayText; $vuLbl.TextAlign = [ContentAlignment]::MiddleLeft
    $f.Controls.Add($vuLbl)

    $vu = New-Object Panel; $vu.Bounds = [Rectangle]::new(16,$vuTop+14,$FW-32,12)
    $vu.BackColor = [Color]::FromArgb(228,228,228)
    $script:VuPanel = $vu   # assign to script scope BEFORE the closure captures it
    $vu.add_Paint({
        param($sender,$e)
        $g = $e.Graphics
        $w = $sender.Width; $h = $sender.Height
        $lv = [Math]::Max(0.0,[Math]::Min(1.0,$script:VuLevel))
        $pk = [Math]::Max(0.0,[Math]::Min(1.0,$script:VuPeak))
        $g.FillRectangle([Brushes]::WhiteSmoke, 0, 0, $w, $h)
        if ($lv -gt 0.001 -and $w -gt 2) {
            $filled = [int]($lv * $w)
            if ($filled -gt 0) {
                # Reuse a cached brush; only recreate when accent changes (never in practice)
                if (-not $script:VuBrush -or $script:VuBrush.IsDisposed) {
                    $cA = $Accent
                    $cB = [Color]::FromArgb(255,[Math]::Min(255,$cA.R+55),[Math]::Min(255,$cA.G+55),[Math]::Min(255,$cA.B+55))
                    $script:VuBrush = New-Object LinearGradientBrush([Point]::new(0,0),[Point]::new([Math]::Max(1,$w),0),$cA,$cB)
                }
                $g.FillRectangle($script:VuBrush, 0, 0, $filled, $h)
            }
        }
        $px = [int]($pk * ([float][Math]::Max(1,$w) - 2.0))
        if ($px -gt 2) {
            $pc = New-Object Pen($AccentDark, 2); $g.DrawLine($pc,$px,1,$px,$h-2); $pc.Dispose()
        }
        $g.DrawRectangle([SystemPens]::ControlDark, 0, 0, $w-1, $h-1)
    })
    $f.Controls.Add($vu)

    $statsTop = $vuTop + 14 + 12 + 4
    $stLbl = New-Object Label; $stLbl.AutoSize = $false
    $stLbl.Bounds = [Rectangle]::new(16,$statsTop,$FW-32,14)
    $stLbl.Text = '-- pkt/s  .  -- drops'
    $stLbl.Font = $FontTiny; $stLbl.ForeColor = [SystemColors]::GrayText
    $stLbl.TextAlign = [ContentAlignment]::MiddleLeft
    $f.Controls.Add($stLbl); $script:StatsLbl = $stLbl

    $volTop = $statsTop + 17
    $volHdr = New-Object Label; $volHdr.AutoSize = $false
    $volHdr.Bounds = [Rectangle]::new(16,$volTop,$FW-32,14)
    $volHdr.Text = 'OUTPUT VOLUME (UP TO 200%)'; $volHdr.Font = $FontTiny
    $volHdr.ForeColor = [SystemColors]::GrayText
    $f.Controls.Add($volHdr)
    $volBar = New-Object TrackBar
    $volBar.Minimum = 0; $volBar.Maximum = 200; $volBar.TickFrequency = 20
    $volBar.SmallChange = 1; $volBar.LargeChange = 5
    $volBar.AutoSize = $false; $volBar.Height = 28
    $volBar.Bounds = [Rectangle]::new(10,$volTop+12,224,28)
    $volBar.Value = [Math]::Max(0,[Math]::Min(200,[int]$Cfg.Volume))
    $script:VolumeBar = $volBar
    $volValue = New-Object Label; $volValue.AutoSize = $false
    $volValue.Bounds = [Rectangle]::new(238,$volTop+15,56,20)
    $volValue.Font = $FontVal; $volValue.TextAlign = [ContentAlignment]::MiddleRight
    $volValue.Text = "$($volBar.Value)%"; $script:VolumeLbl = $volValue
    $volBar.add_ValueChanged({
        $v = [int]$script:VolumeBar.Value
        [WaveRouter]::PlaybackVolume = $v / 100.0
        $Cfg.Volume = $v
        if ($script:VolumeLbl) { $script:VolumeLbl.Text = "$v%" }
    })
    $volBar.add_MouseUp({ Save-ReceiverConfig })
    $volBar.add_KeyUp({ Save-ReceiverConfig })
    $volBar.add_Leave({ Save-ReceiverConfig })
    $f.Controls.Add($volBar); $f.Controls.Add($volValue)
    $divY = $volTop + 44
    $div = New-Object Panel; $div.Bounds = [Rectangle]::new(0,$divY,$FW,1)
    $div.BackColor = [SystemColors]::ControlLight; $f.Controls.Add($div)

    $footY = $divY + 1
    $foot = New-Object Panel; $foot.Bounds = [Rectangle]::new(0,$footY,$FW,$FH-$footY)
    $foot.BackColor = [SystemColors]::Control; $f.Controls.Add($foot)

    $btnData = @(
        @{ T='Restart'; X=10;  A={ Request-RestartRecv; Refresh-Flyout } }
        @{ T='Stop';    X=82;  A={ $script:RestartPending=$false; Stop-Recv; Set-TrayState 'idle'; Refresh-Flyout } }
        @{ T='Quit';    X=226; A={
            $Poll.Stop(); Stop-PingJob; $script:RestartPending=$false; Stop-Recv
            if ($script:RecvHandle) {
                try { $null = $script:RecvHandle.AsyncWaitHandle.WaitOne(1200) } catch {}
                Complete-RecvWorker
            }
            Restore-EndpointLabel
            if ($script:VuBrush) { try{$script:VuBrush.Dispose()}catch{} }
            if ($script:Flyout) { try {$script:Flyout.Dispose()} catch {} }
            try { $Ctx.Dispose() } catch {}
            $Tray.Visible=$false; $Tray.Dispose()
            foreach ($ico in $Icons.Values) { try {$ico.Dispose()} catch {} }
            foreach ($font in @($FontUI,$FontKey,$FontVal,$FontHead,$FontTiny)) { try {$font.Dispose()} catch {} }
            [Application]::Exit()
        } }
    )
    foreach ($d in $btnData) {
        $b = New-Object Button; $b.Text = $d.T; $b.FlatStyle = [FlatStyle]::System
        $b.Bounds = [Rectangle]::new($d.X,8,64,28); $b.add_Click($d.A); $foot.Controls.Add($b)
    }
    $muteBtn = New-Object Button; $muteBtn.FlatStyle = [FlatStyle]::System
    $muteBtn.Text = 'Sync...'; $muteBtn.Enabled = $false
    $muteBtn.Bounds = [Rectangle]::new(154,8,64,28)
    $muteBtn.add_Click({
        $cmd = if ($script:MicMuted) { 'unmute' } else { 'mute' }
        if (Send-LinuxCmd $cmd) { $script:MuteBtn.Enabled = $false; $script:MuteBtn.Text = 'Waiting...' }
    })
    $foot.Controls.Add($muteBtn); $script:MuteBtn = $muteBtn

    return $f
}

function Update-LevelLabel {
    $lv = if ($script:Flyout -and $script:Flyout.Visible) { [WaveRouter]::VuLevel } else { -1 }
    if ($lv -lt 0) { return }
    $ll = $script:Labels['Level']; if (-not $ll) { return }
    if ($lv -gt 0.000001) {
        $db = [Math]::Round(20.0 * [Math]::Log10([double]$lv), 1)
        $ll.Text = "$db dBFS"
        if   ($db -gt -3)    { $ll.ForeColor = $ColorErr  }
        elseif ($db -gt -18) { $ll.ForeColor = $ColorOk   }
        else                 { $ll.ForeColor = $ColorWarn  }
    } else {
        $ll.Text = "-inf dBFS"
        $ll.ForeColor = [SystemColors]::GrayText
    }
}

function Refresh-Flyout {
    if (-not $script:Flyout) { return }
    $sunUp     = Test-SunshineUp
    $listening = [WaveRouter]::Running
    $streaming = $listening -and [WaveRouter]::HasRecentPackets()

    $lSun = $script:Labels['Sunshine']
    if ($sunUp) { $lSun.Text='running';  $lSun.ForeColor=$ColorOk }
    else        { $lSun.Text='offline';  $lSun.ForeColor=[SystemColors]::GrayText }

    $lRec = $script:Labels['Receiver']
    if ($streaming) { $lRec.Text='receiving'; $lRec.ForeColor=$ColorOk }
    elseif ($listening) { $lRec.Text='waiting for audio'; $lRec.ForeColor=$ColorWarn }
    elseif ([WaveRouter]::LastError) { $lRec.Text='error'; $lRec.ForeColor=$ColorErr }
    else { $lRec.Text='stopped'; $lRec.ForeColor=[SystemColors]::GrayText }

    $script:Labels['Uptime'].Text      = Get-Uptime
    $script:Labels['Uptime'].ForeColor = [SystemColors]::ControlDarkDark

    $lDev = $script:Labels['Device']
    if (-not $script:CableFound) {
        $lDev.Text='CABLE not found'; $lDev.ForeColor=$ColorErr
    } elseif ([WaveRouter]::LastError) {
        $lDev.Text='receiver error'; $lDev.ForeColor=$ColorErr
    } elseif ($streaming) {
        $lDev.Text='CABLE Input (live)'; $lDev.ForeColor=$ColorOk
    } elseif ($listening) {
        $lDev.Text='CABLE ready; no packets'; $lDev.ForeColor=$ColorWarn
    } else {
        $lDev.Text='ready'; $lDev.ForeColor=[SystemColors]::GrayText
    }

    $lRem = $script:Labels['Remote']
    $ip = [WaveRouter]::SourceIP
    if ($streaming -and $ip -and $ip -ne '--') {
        $lRem.Text = $ip
        $lRem.ForeColor = [SystemColors]::ControlDarkDark
    } elseif ($ip -and $ip -ne '--') {
        $lRem.Text = "last $ip"
        $lRem.ForeColor = [SystemColors]::GrayText
    } else {
        $lRem.Text = '--'
        $lRem.ForeColor = [SystemColors]::GrayText
    }

    if ($script:StatsLbl) {
        $cur  = [WaveRouter]::PktsReceived
        $pps  = [Math]::Round(($cur - $script:LastPkts) / 2.0, 0)
        $script:LastPkts = $cur
        $drops = [WaveRouter]::PktsDropped
        if ($streaming) {
            $under = [WaveRouter]::Underruns
            $bad = [WaveRouter]::GetRejectedPackets()
            $clip = [WaveRouter]::GetClippedSamples()
            $buf = [WaveRouter]::PreBuf
            $jit = [Math]::Round([WaveRouter]::ArrivalJitterMs, 1)
            $script:StatsLbl.Text      = "$pps/s  buf:$buf  jit:$($jit)ms  drop:$drops  bad:$bad  under:$under  clip:$clip"
            $script:StatsLbl.ForeColor = if ($drops -gt 0 -or $bad -gt 0 -or $under -gt 0 -or $clip -gt 0) { $ColorWarn } else { [SystemColors]::GrayText }
        } else {
            $script:StatsLbl.Text      = '-- pkt/s  .  -- drops'
            $script:StatsLbl.ForeColor = [SystemColors]::GrayText
        }
    }

    if ($script:Labels['Source']) { $script:Labels['Source'].Text = "$($script:MicSource) (Nobara)" }
    if ($script:MuteBtn) {
        $script:MuteBtn.Enabled = $script:MuteKnown
        $script:MuteBtn.Text = if (-not $script:MuteKnown) { 'Sync...' } elseif ($script:MicMuted) { 'Unmute' } else { 'Mute' }
    }
    if ($script:VolumeBar -and $script:VolumeLbl) { $script:VolumeLbl.Text = "$([int]$script:VolumeBar.Value)%" }
}

function Show-Flyout {
    if (-not $script:Flyout) { $script:Flyout = Build-Flyout }
    if ($script:Flyout.Visible) { $script:Flyout.Hide(); return }
    $script:LastPkts = [WaveRouter]::PktsReceived
    Refresh-Flyout
    $wa = [Screen]::PrimaryScreen.WorkingArea
    $script:Flyout.Left = $wa.Right  - $script:Flyout.Width  - 12
    $script:Flyout.Top  = $wa.Bottom - $script:Flyout.Height - 4
    $script:Flyout.Show(); $script:Flyout.BringToFront(); $script:Flyout.Activate()
}

$Ctx = New-Object ContextMenuStrip; $Ctx.Font = $FontUI
$MiTitle = New-Object ToolStripMenuItem('Roaring Mic'); $MiTitle.Enabled = $false; $MiTitle.Font = $FontHead
$Ctx.Items.Add($MiTitle) | Out-Null
$Ctx.Items.Add((New-Object ToolStripSeparator)) | Out-Null
$MiRst = New-Object ToolStripMenuItem('Restart receiver'); $MiRst.add_Click({ Request-RestartRecv }); $Ctx.Items.Add($MiRst) | Out-Null
$MiStp = New-Object ToolStripMenuItem('Stop receiver');    $MiStp.add_Click({ $script:RestartPending=$false; Stop-Recv; Set-TrayState 'idle' }); $Ctx.Items.Add($MiStp) | Out-Null
$Ctx.Items.Add((New-Object ToolStripSeparator)) | Out-Null
$MiQuit = New-Object ToolStripMenuItem('Quit')
$MiQuit.add_Click({
    $Poll.Stop(); Stop-PingJob; $script:RestartPending=$false; Stop-Recv
    if ($script:RecvHandle) {
        try { $null = $script:RecvHandle.AsyncWaitHandle.WaitOne(1200) } catch {}
        Complete-RecvWorker
    }
    Restore-EndpointLabel
    if ($script:VuBrush) { try{$script:VuBrush.Dispose()}catch{} }
    if ($script:Flyout) { try {$script:Flyout.Dispose()} catch {} }
    try { $Ctx.Dispose() } catch {}
    $Tray.Visible=$false; $Tray.Dispose()
    foreach ($ico in $Icons.Values) { try {$ico.Dispose()} catch {} }
    foreach ($font in @($FontUI,$FontKey,$FontVal,$FontHead,$FontTiny)) { try {$font.Dispose()} catch {} }
    [Application]::Exit()
})
$Ctx.Items.Add($MiQuit) | Out-Null
$Ctx.add_Opening({
    if ([WaveRouter]::Running)    { $MiTitle.Text = "  Live  |  :$($Cfg.Port)  |  $(Get-Uptime)  |  $([WaveRouter]::SourceIP)" }
    elseif (Test-SunshineUp)      { $MiTitle.Text = '  Sunshine up  |  receiver stopped' }
    else                          { $MiTitle.Text = '  Waiting for Sunshine...' }
})
$Tray.ContextMenuStrip = $Ctx
$Tray.add_MouseClick({ param($s,$e); if ($e.Button -eq [MouseButtons]::Left) { Show-Flyout } })

# ── Network / roaming detection ─────────────────────────────────────────────
# IMPORTANT: All network I/O runs on background runspaces, never on the UI
# thread. Ping.Send(800ms) and WebClient.DownloadString on the timer thread
# stall the message pump, causing VU stutter and queued Restart crashes.
# The PC. This was hardcoded to 192.168.50.132 -- the laptop's own address --
# so every Swap/Mute command was sent to this machine and the presence ping
# pinged itself, which can never fail and so never noticed the PC going away.
$script:LinuxHost      = $Cfg.PcHost
$script:CmdPort        = 46002

function Send-LinuxCmd([string]$cmd) {
    if ($script:CmdPending) { return $false }
    $script:CmdPending = $true
    $script:CmdName = $cmd
    $host_ = $script:LinuxHost
    $port_ = $script:CmdPort
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($h,$port,$command)
        $udp = $null
        try {
            $udp = New-Object System.Net.Sockets.UdpClient
            $udp.Client.ReceiveTimeout = 7000
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($command)
            [void]$udp.Send($bytes,$bytes.Length,$h,$port)
            $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any,0)
            $reply = $udp.Receive([ref]$ep)
            return [System.Text.Encoding]::UTF8.GetString($reply)
        } catch { return ('transport-error:' + $_.Exception.Message) }
        finally { if ($udp) { $udp.Close() } }
    }).AddArgument($host_).AddArgument($port_).AddArgument($cmd)
    $script:CmdRunspace = $rs
    $script:CmdPowerShell = $ps
    $script:CmdHandle = $ps.BeginInvoke()
    return $true
}

function Complete-LinuxCmd {
    if (-not $script:CmdPending -or -not $script:CmdHandle -or -not $script:CmdHandle.IsCompleted) { return }
    $cmd = $script:CmdName
    $reply = ''
    try {
        $out = $script:CmdPowerShell.EndInvoke($script:CmdHandle)
        if ($out.Count -gt 0) { $reply = [string]$out[0] }
    } catch { $reply = 'transport-error:' + $_.Exception.Message }
    try { $script:CmdPowerShell.Dispose(); $script:CmdRunspace.Close(); $script:CmdRunspace.Dispose() } catch {}
    $script:CmdPowerShell = $null; $script:CmdRunspace = $null; $script:CmdHandle = $null
    $script:CmdPending = $false; $script:CmdName = ''

    $ok = $false
    if ($cmd -eq 'mute' -and $reply -match '^ok:mute:') { $script:MicMuted = $true; $ok = $true }
    elseif ($cmd -eq 'unmute' -and $reply -match '^ok:unmute:') { $script:MicMuted = $false; $ok = $true }
    elseif ($cmd -like 'set-mic:*' -and $reply -match '^accepted:mic=(.+)$') {
        $acceptedTarget = [string]$Matches[1]
        if ($acceptedTarget -eq $script:SwapTarget) {
            $script:MicSource = "$($script:SwapTarget) (applying)"
            $script:StatusPollCount = 0
            $script:StatusPollDue = [DateTime]::Now.AddMilliseconds(300)
            if ($script:Labels['Source']) { $script:Labels['Source'].Text = "$($script:MicSource) (Nobara)" }
            $ok = $true
        }
    }
    elseif ($cmd -eq 'status' -and $reply -match '^(ok|pending):mic=([^:]+):muted=(yes|no)$') {
        $routeState = [string]$Matches[1]
        $reportedMic = [string]$Matches[2]
        $script:MicMuted = ($Matches[3] -eq 'yes')
        $script:MuteKnown = $true
        if ($routeState -eq 'ok' -and (-not $script:SwapTarget -or $reportedMic -eq $script:SwapTarget)) {
            $script:MicSource = $reportedMic
            $script:SwapTarget = ''
            $script:RouteKnown = $true
            $script:SwapRetryReady = $false
            $script:StatusPollDue = $null
        } elseif ($routeState -eq 'pending') {
            $script:RouteKnown = $false
            $script:MicSource = if ($script:SwapTarget) { "$reportedMic (switching to $($script:SwapTarget))" } else { "$reportedMic (not confirmed)" }
            $script:StatusPollCount++
            if ($script:StatusPollCount -lt 10) {
                $script:StatusPollDue = [DateTime]::Now.AddSeconds(1)
            } else {
                $script:SwapRetryReady = [bool]$script:SwapTarget
                $script:StatusPollDue = [DateTime]::Now.AddSeconds(5)
                if ($script:SwapRetryReady -and $script:StatusPollCount -eq 10) {
                    $Tray.BalloonTipTitle = 'Roaring Mic route not confirmed'
                    $Tray.BalloonTipText = 'The requested input is still not in the live graph. Retry will resend the same target safely.'
                    $Tray.BalloonTipIcon = [ToolTipIcon]::Warning; $Tray.ShowBalloonTip(4000)
                }
            }
        } else {
            # The previous route is still live while a requested swap is applying.
            $script:RouteKnown = $false
            $script:MicSource = "$reportedMic (switching to $($script:SwapTarget))"
            $script:StatusPollCount++
            if ($script:StatusPollCount -lt 10) { $script:StatusPollDue = [DateTime]::Now.AddSeconds(1) }
            else {
                $script:SwapRetryReady = [bool]$script:SwapTarget
                $script:StatusPollDue = [DateTime]::Now.AddSeconds(5)
                if ($script:SwapRetryReady -and $script:StatusPollCount -eq 10) {
                    $Tray.BalloonTipTitle = 'Roaring Mic route not confirmed'
                    $Tray.BalloonTipText = 'The route change is still unconfirmed. Retry will resend the same target safely.'
                    $Tray.BalloonTipIcon = [ToolTipIcon]::Warning; $Tray.ShowBalloonTip(4000)
                }
            }
        }
        if ($script:Labels['Source']) { $script:Labels['Source'].Text = "$($script:MicSource) (Nobara)" }
        $ok = $true
    }
    elseif ($cmd -like 'set-mic:*') {
        # Even without the command ACK, query the actual route before allowing
        # another input action. The command is idempotent, so retry is safe.
        $script:StatusPollCount = 0
        $script:StatusPollDue = [DateTime]::Now.AddMilliseconds(300)
        $ok = $true
    }
    elseif ($cmd -eq 'status' -and -not $ok -and $script:SwapTarget) {
        $script:StatusPollCount++
        if ($script:StatusPollCount -lt 10) {
            $script:StatusPollDue = [DateTime]::Now.AddSeconds(1)
            $ok = $true
        } else {
            $script:SwapRetryReady = $true
            $script:StatusPollDue = [DateTime]::Now.AddSeconds(5)
            if ($script:StatusPollCount -eq 10) {
                $Tray.BalloonTipTitle = 'Roaring Mic route not confirmed'
                $Tray.BalloonTipText = 'Linux did not confirm the requested route. Retry will resend the same target safely.'
                $Tray.BalloonTipIcon = [ToolTipIcon]::Warning; $Tray.ShowBalloonTip(4000)
            }
        }
    }
    elseif ($cmd -eq 'status' -and -not $ok) {
        # Retry the initial status sync after a lost reply. Keep controls disabled.
        $script:MuteKnown = $false
        $script:RouteKnown = $false
        $script:StatusPollDue = [DateTime]::Now.AddSeconds(3)
        $ok = $true
    }

    if ($script:MuteBtn) {
        $script:MuteBtn.Enabled = $script:MuteKnown
        $script:MuteBtn.Text = if (-not $script:MuteKnown) { 'Sync...' } elseif ($script:MicMuted) { 'Unmute' } else { 'Mute' }
    }
    if ($script:SwapBtn) {
        $script:SwapBtn.Enabled = $script:MuteKnown -and ($script:RouteKnown -or $script:SwapRetryReady)
        $script:SwapBtn.Text = if ($script:SwapTarget -and $script:SwapRetryReady) { 'Retry route' } elseif ($script:SwapTarget) { 'Applying...' } elseif ($script:RouteKnown) { 'Swap input' } else { 'Sync...' }
    }
    if (-not $ok) {
        $Tray.BalloonTipTitle = 'Roaring Mic command not confirmed'
        $Tray.BalloonTipText = if ($reply) { "$cmd - $reply" } else { "$cmd - no acknowledgement received" }
        $Tray.BalloonTipIcon = [ToolTipIcon]::Warning
        $Tray.ShowBalloonTip(3500)
    }
}

$script:NetOkStreak    = 0
$script:NetBadStreak   = 0
$script:NetworkOk      = $true
$script:RoamBalloon    = $false
# Async ping result is consumed once per completed probe.
$script:PingResult     = $false
$script:PingFresh      = $false
$script:PingRunning    = $false
$script:PingRunspace   = $null
$script:PingPowerShell = $null
$script:PingHandle     = $null
$script:PingTimer      = $null

function Start-PingJob {
    if ($script:PingRunning) { return }
    $script:PingRunning = $true
    $rs = $null; $ps = $null
    try {
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        $host_ = $script:LinuxHost
        [void]$ps.AddScript({
            param($h)
            $p = New-Object System.Net.NetworkInformation.Ping
            try { $r = $p.Send($h, 800); return ($r.Status -eq 0) }
            catch { return $false } finally { $p.Dispose() }
        }).AddArgument($host_)
        $handle = $ps.BeginInvoke()
        $script:PingRunspace = $rs
        $script:PingPowerShell = $ps
        $script:PingHandle = $handle
        $t = New-Object System.Windows.Forms.Timer
        $t.Interval = 120
        $script:PingTimer = $t
        $t.add_Tick({
            if (-not $script:PingHandle -or -not $script:PingHandle.IsCompleted) { return }
            if ($script:PingTimer) { $script:PingTimer.Stop(); $script:PingTimer.Dispose() }
            $script:PingTimer = $null
            try {
                $out = $script:PingPowerShell.EndInvoke($script:PingHandle)
                $script:PingResult = if ($out.Count -gt 0) { [bool]$out[0] } else { $false }
            } catch { $script:PingResult = $false }
            try { $script:PingPowerShell.Dispose() } catch {}
            try { $script:PingRunspace.Close(); $script:PingRunspace.Dispose() } catch {}
            $script:PingPowerShell = $null; $script:PingRunspace = $null; $script:PingHandle = $null
            $script:PingRunning = $false
            $script:PingFresh = $true
        }.GetNewClosure())
        $t.Start()
    } catch {
        if ($ps) { try { $ps.Dispose() } catch {} }
        if ($rs) { try { $rs.Close(); $rs.Dispose() } catch {} }
        $script:PingPowerShell = $null; $script:PingRunspace = $null; $script:PingHandle = $null
        $script:PingRunning = $false
        $script:PingResult = $false
        $script:PingFresh = $true
    }
}

function Stop-PingJob {
    if ($script:PingTimer) {
        try { $script:PingTimer.Stop(); $script:PingTimer.Dispose() } catch {}
        $script:PingTimer = $null
    }
    if ($script:PingHandle -and $script:PingPowerShell) {
        try { $null = $script:PingHandle.AsyncWaitHandle.WaitOne(1100) } catch {}
        if ($script:PingHandle.IsCompleted) {
            try { $null = $script:PingPowerShell.EndInvoke($script:PingHandle) } catch {}
        } else {
            try { $script:PingPowerShell.Stop() } catch {}
        }
    }
    if ($script:PingPowerShell) { try { $script:PingPowerShell.Dispose() } catch {} }
    if ($script:PingRunspace) { try { $script:PingRunspace.Close(); $script:PingRunspace.Dispose() } catch {} }
    $script:PingPowerShell = $null; $script:PingRunspace = $null; $script:PingHandle = $null
    $script:PingRunning = $false; $script:PingFresh = $false
}

# -- CABLE Output display name ------------------------------------------
# Windows shows a capture device as "<endpoint name> (<device name>)" and the
# endpoint half is just a registry string. Rewriting it means the microphone
# listed in Discord, OBS and Windows itself states whether the PC is actually
# feeding it, instead of every app showing a generic "CABLE Output".
$EndpointProp = '{b3f8fa53-0004-438e-9003-51a46e139bf2},6'
$DeviceProp   = '{b3f8fa53-0004-438e-9003-51a46e139bf2},2'
$script:EndpointKey  = $null
$script:EndpointOrig = 'CABLE Output'
$script:EndpointNow  = $null

function Find-CableEndpoint {
    $base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'
    foreach ($k in (Get-ChildItem $base -EA SilentlyContinue)) {
        $props = Join-Path $k.PSPath 'Properties'
        $name = (Get-ItemProperty $props -Name $EndpointProp -EA SilentlyContinue).$EndpointProp
        $dev  = (Get-ItemProperty $props -Name $DeviceProp   -EA SilentlyContinue).$DeviceProp
        if (-not $name) { continue }
        $isCable = ($name -match 'CABLE Output' -or $name -match 'Nobara Mic')
        if (-not $isCable -and $dev -and $dev -match 'VB-Audio Virtual Cable') { $isCable = $true }
        if ($isCable) {
            $script:EndpointKey = $props
            # Never record one of our own labels as the name to restore.
            if ($name -notmatch 'Nobara Mic') { $script:EndpointOrig = $name }
            $script:EndpointNow = $name
            return
        }
    }
}

function Set-EndpointLabel([string]$text) {
    if (-not $script:EndpointKey) { return }
    if ($script:EndpointNow -eq $text) { return }
    # Needs HKLM; the task runs elevated. A denied write is not worth a dialog,
    # it just means the device keeps its old name.
    try {
        Set-ItemProperty -Path $script:EndpointKey -Name $EndpointProp -Value $text -EA Stop
        $script:EndpointNow = $text
    } catch {}
}

function Restore-EndpointLabel { Set-EndpointLabel $script:EndpointOrig }

Find-CableEndpoint

function Enter-RoamState {
    if (-not $script:NetworkOk) { return }
    $script:NetworkOk = $false
    $script:RestartPending = $false
    Stop-Recv
    if ($script:Flyout -and $script:Flyout.Visible) { $script:Flyout.Hide() }
    Set-TrayState 'idle'
    $Tray.Text = 'Roaring Mic -- PC not reachable'
    Set-EndpointLabel 'Nobara Mic (offline)'
    if (-not $script:RoamBalloon) {
        $script:RoamBalloon = $true
        $Tray.BalloonTipTitle = 'Roaring Mic -- offline'
        $Tray.BalloonTipText  = 'Home network not detected. Receiver paused.'
        $Tray.BalloonTipIcon  = [ToolTipIcon]::Warning
        $Tray.ShowBalloonTip(4000)
    }
}

function Leave-RoamState {
    if ($script:NetworkOk) { return }
    $script:NetworkOk    = $true
    $script:RoamBalloon  = $false
    $script:WasUp        = $false   # force re-check of Sunshine on next tick
    $Tray.BalloonTipTitle = 'Roaring Mic -- back online'
    $Tray.BalloonTipText  = 'Home network detected. Resuming...'
    $Tray.BalloonTipIcon  = [ToolTipIcon]::Info
    $Tray.ShowBalloonTip(2500)
}

# Seed external IP and initial ping asynchronously
Start-PingJob

$script:WasUp        = $false
$script:TickCount    = 0
$script:NetTickCount = 0
$script:VuBrush      = $null

# Assume network ok at startup; first async ping result will correct if wrong
$script:NetworkOk = $true

$Poll = New-Object System.Windows.Forms.Timer; $Poll.Interval = 100
$Poll.add_Tick({
    Complete-RecvWorker
    if ($script:IsStreaming -and -not [WaveRouter]::Running -and -not $script:RecvPS -and
        $script:RecvRetryAt -ne [datetime]::MinValue -and [datetime]::Now -ge $script:RecvRetryAt) {
        $script:RecvRetryAt = [datetime]::MinValue
        Start-Recv
    }
    Complete-LinuxCmd
    if (-not $script:CmdPending -and $script:StatusPollDue -and [DateTime]::Now -ge $script:StatusPollDue) {
        $script:StatusPollDue = $null
        [void](Send-LinuxCmd 'status')
    }
    Step-Vu
    if ($script:Flyout -and $script:Flyout.Visible) {
        $script:VuPanel.Invalidate()
        Update-LevelLabel
    }

    # ── Network check (fire async ping every 2s, read result immediately) ──
    # Consume only a fresh completed probe. A slow UI tick must not count the
    # same old success/failure repeatedly as if it were multiple new pings.
    $script:NetTickCount = ($script:NetTickCount + 1) % 10
    if ($script:NetTickCount -eq 0) {
        if ($script:PingFresh) {
            $script:PingFresh = $false
            if ($script:PingResult) {
                $script:NetBadStreak = 0; $script:NetOkStreak++
                if (-not $script:NetworkOk -and $script:NetOkStreak -ge 2) { Leave-RoamState }
            } else {
                $script:NetOkStreak = 0; $script:NetBadStreak++
                if ($script:NetworkOk -and $script:NetBadStreak -ge 2) { Enter-RoamState }
            }
        }
        Start-PingJob
    }

    $script:TickCount = ($script:TickCount + 1) % 20
    if ($script:TickCount -ne 0) { return }
    if (-not $script:NetworkOk) { return }

    if ([WaveRouter]::Running -and [WaveRouter]::HasRecentPackets()) {
        Set-EndpointLabel 'Nobara Mic (live)'
    } elseif ($script:NetworkOk) {
        Set-EndpointLabel 'Nobara Mic (ready)'
    } else {
        Set-EndpointLabel 'Nobara Mic (offline)'
    }

    $up = Test-SunshineUp
    if ($up -and -not $script:WasUp) {
        $script:WasUp = $true; Start-Recv
    } elseif (-not $up -and $script:WasUp) {
        $script:WasUp = $false; Stop-Recv
    }
    Save-LearnedSafeBufferProfile
    Refresh-Flyout
})
$Poll.Start()

if (-not $script:CableFound) {
    $Tray.BalloonTipTitle='Roaring Mic -- VB-Cable not found'; $Tray.BalloonTipText='Install VB-Audio Virtual Cable then restart.'
    $Tray.BalloonTipIcon=[ToolTipIcon]::Warning; $Tray.ShowBalloonTip(6000); Set-TrayState 'error'
} elseif (-not $script:NetworkOk) {
    # balloon already shown in Enter-RoamState path; skip
} elseif ($script:WasUp) {
    $Tray.BalloonTipTitle='Roaring Mic'; $Tray.BalloonTipText="Sunshine detected -- starting receiver on :$($Cfg.Port)."
    $Tray.BalloonTipIcon=[ToolTipIcon]::Info; $Tray.ShowBalloonTip(2500)
} else {
    $Tray.BalloonTipTitle='Roaring Mic'; $Tray.BalloonTipText='Ready. Watching for Sunshine...'
    $Tray.BalloonTipIcon=[ToolTipIcon]::None; $Tray.ShowBalloonTip(2000)
}

[Application]::Run()
try { $script:Mtx.ReleaseMutex() } catch {}
