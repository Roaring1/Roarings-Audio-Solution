$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'RoaringMic.ps1'
$launcherPath = Join-Path $root 'RoaringMic-hidden.vbs'

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

[WaveRouter]::ResetCounters()
[WaveRouter]::AllowedSourceIP = '192.168.50.123'
Assert-True ([WaveRouter]::IsAcceptedPacket([byte[]]@(0,1), '192.168.50.123')) 'valid configured-source packet'
Assert-True (-not [WaveRouter]::IsAcceptedPacket([byte[]]@(0,1), '192.168.50.124')) 'wrong source IP rejected'
Assert-True (-not [WaveRouter]::IsAcceptedPacket([byte[]]@(0), '192.168.50.123')) 'odd PCM packet rejected'
$oversized = New-Object byte[] 8194
Assert-True (-not [WaveRouter]::IsAcceptedPacket($oversized, '192.168.50.123')) 'oversized PCM packet rejected'
Assert-True ([WaveRouter]::GetRejectedPackets() -eq 3) 'packet rejection counter'

Assert-True ($source -match '\$volBar\.Minimum\s*=\s*0;\s*\$volBar\.Maximum\s*=\s*200') 'volume slider 0-200 range'
$mutex = [regex]::Match($source, '(?ms)^if \(-not \$script:MtxOwned\) \{(?<body>.*?)^\}')
Assert-True ($mutex.Success -and $mutex.Groups['body'].Value -match 'exit 0') 'duplicate receiver exits cleanly'
Assert-True ($mutex.Groups['body'].Value -notmatch 'MessageBox') 'duplicate receiver has no modal dialog'

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
