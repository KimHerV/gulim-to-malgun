<#
.SYNOPSIS
    Re-applies the fix automatically at every startup and sign-in, so Windows updates cannot bring Gulim back.
.DESCRIPTION
    Copies Apply.ps1 and lib\ to Program Files (only administrators can change them there,
    which matters because the task runs as SYSTEM) and registers a scheduled task that runs
    it with -Quiet. Run again after editing the scripts to update the installed copy.
    Accepts the same options as Apply.ps1.
#>
[CmdletBinding()]
param(
    [string]$TargetFace,
    [switch]$IncludeBatang,
    [switch]$RemoveCapability,
    [switch]$Elevated
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

if (-not (Test-Admin)) {
    Invoke-Elevated $PSCommandPath $PSBoundParameters
    return
}

try {
    New-Item -ItemType Directory -Path (Join-Path $InstallDir 'lib') -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'Apply.ps1') $InstallDir -Force
    Copy-Item (Join-Path $PSScriptRoot 'lib\Common.ps1') (Join-Path $InstallDir 'lib') -Force

    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\Apply.ps1`" -Quiet"
    if ($TargetFace) { $arguments += " -TargetFace `"$TargetFace`"" }
    if ($IncludeBatang) { $arguments += ' -IncludeBatang' }
    if ($RemoveCapability) { $arguments += ' -RemoveCapability' }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $triggers = @(New-ScheduledTaskTrigger -AtStartup; New-ScheduledTaskTrigger -AtLogOn)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal `
        -Settings $settings -Description 'Keeps Gulim rendering as Malgun Gothic after Windows updates.' -Force | Out-Null

    Write-Host "Installed task '$TaskName' -> $InstallDir\Apply.ps1 $($arguments -replace '^.*-Quiet', '-Quiet')"
    Write-Host 'Running it once now...'
    Start-ScheduledTask -TaskName $TaskName
} finally {
    Wait-IfElevated $Elevated
}
