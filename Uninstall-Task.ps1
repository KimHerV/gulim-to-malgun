<#
.SYNOPSIS
    Removes the scheduled task and the installed script copy. Keeps backups and logs.
    The current font settings stay as they are; run Restore.ps1 to undo them.
#>
[CmdletBinding()]
param([switch]$Elevated)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

if (-not (Test-Admin)) {
    Invoke-Elevated $PSCommandPath $PSBoundParameters
    return
}

try {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed task '$TaskName'."
    } else {
        Write-Host "Task '$TaskName' is not installed."
    }
    Remove-Item (Join-Path $InstallDir 'Apply.ps1'), (Join-Path $InstallDir 'lib') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Backups and logs are kept in $InstallDir."
} finally {
    Wait-IfElevated $Elevated
}
