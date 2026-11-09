#Requires -Version 5.1
<#
Install or repair the per-user RoaringMicReceiver logon task.

Copy the Windows app files (RoaringMic.ps1 and RoaringMic-hidden.vbs) into:
  %LOCALAPPDATA%\RoaringMic

Run this script from the same interactive Windows account that uses the tray.
An existing task definition is exported to a timestamped XML backup first.
The running receiver is left alone when the task is already active.
#>
[CmdletBinding()]
param(
    [string]$Name = 'RoaringMicReceiver',
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$taskName = $Name
if ([string]::IsNullOrWhiteSpace($taskName)) { throw 'Task name cannot be empty' }
$appDir = Join-Path $env:LOCALAPPDATA 'RoaringMic'
$receiver = Join-Path $appDir 'RoaringMic.ps1'
$launcher = Join-Path $appDir 'RoaringMic-hidden.vbs'

if (-not (Test-Path -LiteralPath $receiver -PathType Leaf)) {
    throw "Receiver script not found: $receiver"
}
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "Windows Script Host launcher not found: $launcher"
}

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
if (-not (Test-Path -LiteralPath $wscript -PathType Leaf)) {
    throw "Windows Script Host not found: $wscript"
}

$oldTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$wasRunning = $false
if ($null -ne $oldTask) {
    $wasRunning = ($oldTask.State -eq 'Running')
    $backupPath = Join-Path $appDir (
        $taskName + '.pre-install-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.xml'
    )
    Export-ScheduledTask -TaskName $taskName |
        Set-Content -LiteralPath $backupPath -Encoding Unicode
    Write-Output "TASK_BACKUP=$backupPath"
}

$action = New-ScheduledTaskAction -Execute $wscript -Argument ('"{0}"' -f $launcher) -WorkingDirectory $appDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'RoaringMic Windows UDP microphone receiver' -Force | Out-Null

$registered = Get-ScheduledTask -TaskName $taskName
if ($registered.Principal.LogonType -ne 'Interactive') {
    throw 'Registered task is not configured for the interactive user session'
}
if ($registered.Settings.IdleSettings.StopOnIdleEnd) {
    throw 'Registered task can still be stopped when the machine becomes idle'
}
if ([System.Xml.XmlConvert]::ToTimeSpan([string]$registered.Settings.ExecutionTimeLimit) -ne [TimeSpan]::Zero) {
    throw 'Registered task still has an execution time limit'
}

if (-not $NoStart -and -not $wasRunning) {
    Start-ScheduledTask -TaskName $taskName
}

if (-not $NoStart) {
    $endpoint = @()
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Milliseconds 500
        $endpoint = @(Get-NetUDPEndpoint -LocalPort 46001 -ErrorAction SilentlyContinue)
        if ($endpoint.Count -eq 1) { break }
    }
    if ($endpoint.Count -ne 1) {
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
        throw "Receiver did not bind UDP 46001. Task result: $($taskInfo.LastTaskResult)"
    }

    $owner = Get-CimInstance Win32_Process |
        Where-Object { $_.ProcessId -eq $endpoint[0].OwningProcess }
    if ($null -eq $owner -or $owner.CommandLine -notlike '*RoaringMic.ps1*') {
        throw 'UDP 46001 is not owned by the RoaringMic receiver process'
    }
}

Write-Output "TASK_NAME=$taskName"
Write-Output "TASK_USER=$identity"
Write-Output "TASK_STATE=$((Get-ScheduledTask -TaskName $taskName).State)"
Write-Output 'IDLE_STOP=False'
Write-Output 'EXECUTION_LIMIT=Unlimited'
Write-Output 'RESTARTS=3 at 1-minute intervals'
Write-Output "PRESERVED_RUNNING_INSTANCE=$wasRunning"
if (-not $NoStart) {
    Write-Output 'UDP_46001=LISTENING'
}
