$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$candidatePath = Join-Path $root 'RoaringMic.ps1.candidate'
$scriptPath = if (Test-Path -LiteralPath $candidatePath) {
    $candidatePath
} elseif (Test-Path -LiteralPath (Join-Path $root 'RoaringMic.ps1')) {
    Join-Path $root 'RoaringMic.ps1'
} else {
    $root = Split-Path -Parent $PSScriptRoot
    Join-Path $root 'RoaringMic.ps1'
}
$launcherPath = Join-Path $root 'RoaringMic-hidden.vbs'
$installerPath = Join-Path $root 'Install-RoaringMicTask.ps1'

function Assert-True([bool]$condition, [string]$name) {
    if (-not $condition) { throw "FAIL: $name" }
    Write-Output "PASS: $name"
}

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath, [ref]$tokens, [ref]$parseErrors
) | Out-Null
Assert-True ($parseErrors.Count -eq 0) 'PowerShell parser'

$source = Get-Content -LiteralPath $scriptPath -Raw
$match = [regex]::Match(
    $source,
    "(?s)Add-Type -TypeDefinition @'\s*(.*?)\s*'@ -EA Stop"
)
Assert-True $match.Success 'embedded WaveRouter C# block found'
Add-Type -TypeDefinition $match.Groups[1].Value -ErrorAction Stop
Write-Output 'PASS: embedded WaveRouter C# compile'

# Prove a Stop issued before the worker reaches Run() cannot be undone by a
# delayed worker start. The worker sleeps first, then calls the real Run().
# This path exits at Run()'s initial Running guard and never opens waveOut.
[WaveRouter]::Running = $true
$lateWorker = [System.Management.Automation.PowerShell]::Create()
[void]$lateWorker.AddScript('Start-Sleep -Milliseconds 200; [WaveRouter]::Run()')
$lateHandle = $lateWorker.BeginInvoke()
[WaveRouter]::Stop()
try {
    Assert-True ($lateHandle.AsyncWaitHandle.WaitOne(5000)) 'delayed receiver worker completes after stop'
    $null = $lateWorker.EndInvoke($lateHandle)
}
finally {
    $lateWorker.Dispose()
}
Assert-True (-not [WaveRouter]::Running) 'stop-before-worker-start stays stopped'

# Exercise the real no-device failure path without opening or changing an
# output device: an impossible device name must return before waveOutOpen.
$deviceNeedleBefore = [WaveRouter]::DeviceNeedle
try {
    [WaveRouter]::DeviceNeedle = '__RoaringMic_Test_Device_Does_Not_Exist__'
    [WaveRouter]::Running = $true
    [WaveRouter]::Run()
    Assert-True (-not [WaveRouter]::Running) 'missing output device clears Running'
    Assert-True ([WaveRouter]::LastError -like 'Device * not found*') 'missing output device reports actionable error'
}
finally {
    [WaveRouter]::DeviceNeedle = $deviceNeedleBefore
    [WaveRouter]::Running = $false
}

# Packet freshness is time-bounded and must expire even when the last source IP
# remains displayed in the tray.
[WaveRouter]::LastPacketTicks = [DateTime]::UtcNow.Ticks
Assert-True ([WaveRouter]::HasRecentPackets()) 'fresh packet timestamp is live'
[WaveRouter]::LastPacketTicks = [DateTime]::UtcNow.AddSeconds(-3).Ticks
Assert-True (-not [WaveRouter]::HasRecentPackets()) 'stale packet timestamp expires'
[WaveRouter]::LastPacketTicks = 0
Assert-True (-not [WaveRouter]::HasRecentPackets()) 'empty packet timestamp is not live'

[WaveRouter]::ResetCounters()
[WaveRouter]::PlaybackVolume = 0.0
Assert-True ([WaveRouter]::ScalePcmSample([int16]32767) -eq 0) '0 percent gain'
[WaveRouter]::PlaybackVolume = 1.0
$at100 = @(
    [WaveRouter]::ScalePcmSample([int16]-32768),
    [WaveRouter]::ScalePcmSample([int16]-16384),
    [WaveRouter]::ScalePcmSample([int16]0),
    [WaveRouter]::ScalePcmSample([int16]16384),
    [WaveRouter]::ScalePcmSample([int16]32767)
)
Assert-True (($at100 -join ',') -eq '-32768,-16384,0,16384,32767') '100 percent unity gain'
[WaveRouter]::ResetCounters()
[WaveRouter]::PlaybackVolume = 2.0
$at200 = @(
    [WaveRouter]::ScalePcmSample([int16]-32768),
    [WaveRouter]::ScalePcmSample([int16]-16384),
    [WaveRouter]::ScalePcmSample([int16]0),
    [WaveRouter]::ScalePcmSample([int16]16384),
    [WaveRouter]::ScalePcmSample([int16]32767)
)
Assert-True (($at200 -join ',') -eq '-32768,-32768,0,32767,32767') '200 percent gain saturation'
Assert-True ([WaveRouter]::GetClippedSamples() -eq 3) '200 percent clipping counter'

# Adaptive packet buffering stays at the low floor under normal timing, grows
# quickly when a datagram is late, and never exceeds the bounded device queue.
Assert-True ([WaveRouter]::CalculateAdaptivePreBuf(2, 10.5, 10.0, 2, 8) -eq 2) 'adaptive buffer preserves the safe two-packet floor for normal timing'
Assert-True ([WaveRouter]::CalculateAdaptivePreBuf(2, 16.0, 10.0, 2, 8) -eq 2) 'late packet does not add an unnecessary third packet'
Assert-True ([WaveRouter]::CalculateAdaptivePreBuf(2, 25.0, 10.0, 2, 8) -eq 3) 'adaptive buffer grows to the mathematically required depth'
Assert-True ([WaveRouter]::CalculateAdaptivePreBuf(3, 100.0, 10.0, 2, 8) -eq 8) 'adaptive buffer clamps severe delay to queue cap'
Assert-True ([WaveRouter]::CalculateAdaptivePreBuf(1, 0.0, 10.0, 2, 8) -eq 2) 'adaptive buffer enforces configured safe floor'
Assert-True ([WaveRouter]::CalculateNextSafePreBuf(2, 8) -eq 3) 'actual underrun raises persistent floor by one step, not to transient queue depth'
Assert-True ([WaveRouter]::CalculateNextSafePreBuf(7, 8) -eq 8) 'learned safe floor remains capped at queue maximum'
Assert-True ([WaveRouter]::IsSafePreBufPeerRateMatch('192.168.50.123','192.168.50.123',48000,48000)) 'learned queue profile is scoped to matching peer and rate'
Assert-True (-not [WaveRouter]::IsSafePreBufPeerRateMatch('192.168.50.123','192.168.50.124',48000,48000)) 'learned queue profile is rejected for a different peer'
Assert-True (-not [WaveRouter]::IsSafePreBufPeerRateMatch('192.168.50.123','192.168.50.123',48000,44100)) 'learned queue profile is rejected for a different sample rate'
Assert-True ([WaveRouter]::IsSafePreBufPacketSizeMatch(1024,1024)) 'learned queue profile accepts matching packet size'
Assert-True (-not [WaveRouter]::IsSafePreBufPacketSizeMatch(960,1024)) 'learned queue profile resets after graph packet-size change'
Assert-True (-not [WaveRouter]::IsPacketArrivalLate(5.3, 5.0)) 'normal packet-boundary completion is not classified as late'
Assert-True (-not [WaveRouter]::IsPacketArrivalLate(6.9, 5.0)) 'small scheduling variation is tolerated'
Assert-True ([WaveRouter]::IsPacketArrivalLate(7.1, 5.0)) 'late packet gap is detected'
Assert-True ($source.Contains('inFlight == 0 && LastArrivalWasLate')) 'natural WaveOut packet completion does not count as underrun'
$underrunStart = $source.IndexOf('if (Primed && inFlight == 0 && LastArrivalWasLate) {')
$underrunEnd = $source.IndexOf('if (!Primed)', $underrunStart)
$underrunBlock = if ($underrunStart -ge 0 -and $underrunEnd -gt $underrunStart) { $source.Substring($underrunStart, $underrunEnd - $underrunStart) } else { '' }
Assert-True ($underrunBlock.Length -gt 0 -and -not $underrunBlock.Contains('PreBuf++')) 'one late packet cannot double-increase the adaptive prebuffer'
Assert-True ($source.Contains('StableArrivalCount >= 6000')) 'adaptive buffer reduction requires sustained stability'
Assert-True ($source.Contains('Stopwatch.Frequency * 600L')) 'learned safe floor only decreases after ten wall-clock minutes of stability'
Assert-True ($source.Contains('MinAutoPreBuf = nextFloor')) 'actual WaveOut underrun raises the learned connection floor gradually'
Assert-True ($source.Contains('Stopwatch.Frequency * 5L')) 'persistent safe-floor increases are rate-limited during a burst of underruns'
Assert-True ($source.Contains('Save-ReceiverConfig')) 'learned connection profile is persisted outside the audio receive loop'
$pollStart = $source.IndexOf('$Poll.add_Tick({')
$pollEnd = $source.IndexOf('$Poll.Start()', $pollStart)
$pollBody = if ($pollStart -ge 0 -and $pollEnd -gt $pollStart) { $source.Substring($pollStart, $pollEnd - $pollStart) } else { '' }
Assert-True ($pollBody.Contains('Save-LearnedSafeBufferProfile')) 'learned profile is checked from the always-on timer, not only the visible flyout'
Assert-True ($source.Contains('no-recent-packets')) 'receiver health diagnostics distinguish missing packets from profile-save failure'
Assert-True ($source.Contains('profile-saved')) 'receiver records successful learned-profile persistence'
$saveProfileMatch = [regex]::Match($source, '(?ms)^function Save-LearnedSafeBufferProfile \{.*?^\}')
Assert-True $saveProfileMatch.Success 'learned profile save helper can be isolated for testing'
$script:SafeProfileDiagAt = [datetime]::MinValue
function Write-ReceiverHealthDiagnostic([string]$Message) {}
Invoke-Expression $saveProfileMatch.Value
$Cfg = [PSCustomObject]@{ SafePreBufPkts = 2; SafePreBufPeerIP = ''; SafePreBufRate = 48000; SafePreBufPacketBytes = 0; PcHost = '192.168.50.123'; Rate = 48000 }
$script:SafeProfileSaveRetryAt = [datetime]::MinValue
$script:ProfileWriteCount = 0
function Save-ReceiverConfig { $script:ProfileWriteCount++; return $true }
[WaveRouter]::AdaptiveBuffering = $true
[WaveRouter]::MinAutoPreBuf = 2
[WaveRouter]::LastPacketBytes = 1024
[WaveRouter]::LastPacketTicks = [datetime]::UtcNow.Ticks
Save-LearnedSafeBufferProfile
Assert-True ($script:ProfileWriteCount -eq 1 -and $Cfg.SafePreBufPeerIP -eq '192.168.50.123' -and $Cfg.SafePreBufPacketBytes -eq 1024 -and $Cfg.SafePreBufPkts -eq 2) 'learned profile saves peer, rate, packet size and safe floor'
Save-LearnedSafeBufferProfile
Assert-True ($script:ProfileWriteCount -eq 1) 'unchanged learned profile is not rewritten each timer tick'
function Save-ReceiverConfig { $script:ProfileWriteCount++; return $false }
[WaveRouter]::MinAutoPreBuf = 3
[WaveRouter]::LastPacketBytes = 2048
[WaveRouter]::LastPacketTicks = [datetime]::UtcNow.Ticks
Save-LearnedSafeBufferProfile
Assert-True ($Cfg.SafePreBufPkts -eq 2 -and $Cfg.SafePreBufPacketBytes -eq 1024 -and $script:ProfileWriteCount -eq 2) 'failed profile write restores the in-memory snapshot'
Save-LearnedSafeBufferProfile
Assert-True ($script:ProfileWriteCount -eq 2) 'failed profile write uses a retry delay instead of repeated writes'
Assert-True ($source.Contains('function Save-LearnedSafeBufferProfile')) 'learned profile persistence has a dedicated helper'
$pollStart = $source.IndexOf('$Poll.add_Tick')
$profileSaveCall = $source.IndexOf('Save-LearnedSafeBufferProfile', $pollStart)
$refreshCall = $source.IndexOf('Refresh-Flyout', $pollStart)
Assert-True ($pollStart -ge 0 -and $profileSaveCall -gt $pollStart -and $refreshCall -gt $profileSaveCall) 'learned profile persists from the always-running timer before optional flyout refresh'
Assert-True ($source.Contains('SafeProfileSaveRetryAt')) 'failed profile writes are retried without balloon-notification spam'

[WaveRouter]::AdaptiveBuffering = $true
[WaveRouter]::ConfiguredPreBuf = 5
[WaveRouter]::MinAutoPreBuf = 2
[WaveRouter]::ResetCounters()
Assert-True ([WaveRouter]::PreBuf -eq 2) 'automatic mode starts at the learned two-packet safe floor'
[WaveRouter]::AdaptiveBuffering = $false
[WaveRouter]::ConfiguredPreBuf = 5
[WaveRouter]::ResetCounters()
Assert-True ([WaveRouter]::PreBuf -eq 5) 'manual mode honors configured prebuffer'
[WaveRouter]::AdaptiveBuffering = $true
Assert-True ($source -match 'const int NBUF = MaxAutoPreBuf;') 'WaveOut queue depth is bounded to adaptive maximum'
Assert-True ($source.Contains('udp.Client.ReceiveBufferSize = 8192;')) 'UDP receive buffer is bounded for low latency'
Assert-True ($source.Contains('[Math]::Min(8,[int]$Cfg.PreBufPkts)')) 'manual prebuffer config is clamped to bounded maximum'

[WaveRouter]::ResetCounters()
[WaveRouter]::AllowedSourceIP = '192.168.50.123'
Assert-True ([WaveRouter]::IsAcceptedPacket([byte[]]@(0,1), '192.168.50.123')) 'valid configured-source packet'
Assert-True (-not [WaveRouter]::IsAcceptedPacket([byte[]]@(0,1), '192.168.50.124')) 'wrong source IP rejected'
Assert-True (-not [WaveRouter]::IsAcceptedPacket([byte[]]@(0), '192.168.50.123')) 'odd PCM packet rejected'
$oversized = New-Object byte[] 8194
Assert-True (-not [WaveRouter]::IsAcceptedPacket($oversized, '192.168.50.123')) 'oversized PCM packet rejected'
Assert-True ([WaveRouter]::GetRejectedPackets() -eq 3) 'packet rejection counter'

Assert-True ($source -match '\$volBar\.Minimum\s*=\s*0;\s*\$volBar\.Maximum\s*=\s*200') 'volume slider 0-200 range'
Assert-True ($source.Contains('if (-not $script:MtxOwned)')) 'duplicate-instance mutex guard present'
Assert-True ($source.Contains('exit 0')) 'duplicate receiver exits cleanly'
Assert-True (-not $source.Contains("MessageBox.Show('RoaringMic is already running'")) 'duplicate receiver has no modal dialog'

$installTokens = $null
$installErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $installerPath, [ref]$installTokens, [ref]$installErrors
) | Out-Null
Assert-True ($installErrors.Count -eq 0) 'task installer PowerShell parser'
$installer = Get-Content -LiteralPath $installerPath -Raw
Assert-True ($installer.Contains('-DontStopOnIdleEnd')) 'task idle-stop disabled'
Assert-True ($installer.Contains('-ExecutionTimeLimit ([TimeSpan]::Zero)')) 'task execution limit disabled'
Assert-True ($installer.Contains('-RestartCount 3')) 'task recovery restart policy'
Assert-True ($installer.Contains('-MultipleInstances IgnoreNew')) 'duplicate task starts ignored'
Assert-True ($installer.Contains('Export-ScheduledTask')) 'prior task definition backed up'
Assert-True ($installer.Contains("-LogonType Interactive")) 'task launches in interactive session'
Assert-True ($installer.Contains('$registered.Principal.LogonType')) 'task principal verified through ScheduledTask object'
Assert-True ($installer.Contains('[System.Xml.XmlConvert]::ToTimeSpan')) 'task time limit verified from XML duration'

$launcherSource = Get-Content -LiteralPath $launcherPath -Raw
$vb = [regex]::Replace($launcherSource, '(?m)^command\s*=.*$', 'command = "cmd.exe /c exit 0"')
Assert-True ($vb -ne $launcherSource) 'launcher command safely stubbed for parser test'
$tempVbs = Join-Path $env:TEMP ('RoaringMic-vbs-' + [guid]::NewGuid().ToString('N') + '.vbs')
try {
    [System.IO.File]::WriteAllText($tempVbs, $vb, [System.Text.Encoding]::ASCII)
    $cscript = Join-Path $env:WINDIR 'System32\cscript.exe'
    $process = Start-Process -FilePath $cscript -ArgumentList @('//nologo', '//B', $tempVbs) -Wait -PassThru -NoNewWindow
    Assert-True ($process.ExitCode -eq 0) 'Windows Script Host launcher syntax and wait behavior'
}
finally {
    Remove-Item -LiteralPath $tempVbs -Force -ErrorAction SilentlyContinue
}

Write-Output 'WINDOWS_VALIDATION=PASS'
