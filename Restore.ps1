<#
.SYNOPSIS
    Puts the font registry keys back the way they were before Apply.ps1 first ran.
.PARAMETER Stamp
    Restore a specific backup (yyyyMMdd-HHmmss) instead of the oldest one.
.PARAMETER AddCapability
    Also reinstall the Korean Supplemental Fonts feature. Needs an internet connection.
#>
[CmdletBinding()]
param(
    [string]$Stamp,
    [switch]$AddCapability,
    [switch]$Elevated
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

if (-not (Test-Admin)) {
    Invoke-Elevated $PSCommandPath $PSBoundParameters
    return
}

try {
    if (-not $Stamp) {
        $oldest = Get-ChildItem $BackupDir -Filter '*-FontSubstitutes.reg' -ErrorAction SilentlyContinue |
            Sort-Object Name | Select-Object -First 1
        if (-not $oldest) { throw "No backups in $BackupDir." }
        $Stamp = $oldest.Name -replace '-FontSubstitutes\.reg$', ''
    }
    $files = @('FontSubstitutes', 'Fonts') | ForEach-Object { Join-Path $BackupDir "$Stamp-$_.reg" }
    foreach ($file in $files) { if (-not (Test-Path $file)) { throw "Missing backup file $file" } }

    # reg import only adds or overwrites, so drop the names this tool manages first;
    # the import then brings back whichever of them existed originally.
    $substitutes = Open-HklmKey $SubstitutesSubKey -Writable
    try {
        foreach ($set in $FontSets.Values) {
            foreach ($name in $set.Names) { $substitutes.DeleteValue($name, $false) }
        }
    } finally { $substitutes.Close() }

    foreach ($file in $files) {
        & reg.exe import $file /reg:64 2>$null
        if ($LASTEXITCODE -ne 0) { throw "reg import failed for $file" }
    }
    Write-Log "Restored font registry keys from backup $Stamp"

    if ($AddCapability) {
        foreach ($capability in Get-WindowsCapability -Online | Where-Object { $_.Name -like $CapabilityPattern -and $_.State -ne 'Installed' }) {
            Add-WindowsCapability -Online -Name $capability.Name | Out-Null
            Write-Log "Added capability $($capability.Name)"
        }
    }

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Write-Host 'The scheduled task is still installed and will re-apply at next startup. Run Uninstall-Task.ps1 to stop it.' -ForegroundColor Yellow
    }
    Write-Host 'Sign out and back in (or reboot) for the change to take effect.'
} finally {
    Wait-IfElevated $Elevated
}
