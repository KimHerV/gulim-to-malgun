<#
.SYNOPSIS
    Makes Gulim (and optionally Batang) render as Malgun Gothic. Safe to run repeatedly.
.DESCRIPTION
    FontSubstitutes only applies to names that are not installed, and Windows updates
    re-register gulim.ttc. This script removes that registration (the file stays in place)
    and points every Gulim/Dotum name at the target font. It does nothing when both are
    already in place. Backs up both registry keys before the first change of each run.
.PARAMETER TargetFace
    Font to render instead. Defaults to Malgun Gothic.
.PARAMETER IncludeBatang
    Also replace Batang, BatangChe, Gungsuh and GungsuhChe.
.PARAMETER RemoveCapability
    Also uninstall the Korean Supplemental Fonts feature (removes gulim.ttc and batang.ttc).
    Restore.ps1 -AddCapability puts it back; that needs an internet connection.
.PARAMETER Quiet
    For the scheduled task: never prompt, print nothing when there is nothing to do.
#>
[CmdletBinding()]
param(
    [string]$TargetFace,
    [switch]$IncludeBatang,
    [switch]$RemoveCapability,
    [switch]$Quiet,
    [switch]$Elevated
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
if (-not $TargetFace) { $TargetFace = $DefaultTargetFace }

if (-not (Test-Admin)) {
    if ($Quiet) { throw 'Apply.ps1 -Quiet must run elevated.' }
    Invoke-Elevated $PSCommandPath $PSBoundParameters
    return
}

try {
    if (-not (Get-FamilyNames $TargetFace)) { throw "Target font '$TargetFace' is not installed." }

    $steps = @()
    foreach ($set in Get-FontSets -IncludeBatang:$IncludeBatang) {
        foreach ($name in $set.Names) {
            $current = Get-Substitute $name
            if ($current -ne $TargetFace) { $steps += [pscustomobject]@{ Kind = 'Substitute'; Name = $name; From = $current } }
        }
        foreach ($entry in Get-RegisteredFontEntries $set.File) {
            $steps += [pscustomobject]@{ Kind = 'Unregister'; Name = $entry.Name; From = $entry.Data }
        }
    }

    $capabilities = @()
    if ($RemoveCapability) {
        $capabilities = @(Get-WindowsCapability -Online |
            Where-Object { $_.Name -like $CapabilityPattern -and $_.State -eq 'Installed' })
    }

    if (-not $steps -and -not $capabilities) {
        if (-not $Quiet) { Write-Host "Already applied: Gulim renders as $TargetFace. Nothing to do." }
        return
    }

    $stamp = Backup-FontKeys
    Write-Log "Backed up font registry keys as $stamp"

    $substitutes = Open-HklmKey $SubstitutesSubKey -Writable
    $fonts = Open-HklmKey $FontsSubKey -Writable
    try {
        foreach ($step in $steps) {
            if ($step.Kind -eq 'Substitute') {
                $substitutes.SetValue($step.Name, $TargetFace, 'String')
                Write-Log "Substitute  $($step.Name): '$($step.From)' -> '$TargetFace'"
            } else {
                $fonts.DeleteValue($step.Name)
                Write-Log "Unregister  $($step.Name) = $($step.From)"
            }
        }
    } finally {
        $substitutes.Close()
        $fonts.Close()
    }

    foreach ($capability in $capabilities) {
        Remove-WindowsCapability -Online -Name $capability.Name | Out-Null
        Write-Log "Removed capability $($capability.Name)"
    }

    Write-Log 'Done. Sign out and back in (or reboot) so running apps pick up the change.'
} catch {
    if (Test-Path (Split-Path $LogFile -Parent)) { Add-Content -Path $LogFile -Value "ERROR $_" -Encoding UTF8 }
    throw
} finally {
    Wait-IfElevated $Elevated
}
