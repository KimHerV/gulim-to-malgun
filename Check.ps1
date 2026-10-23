<#
.SYNOPSIS
    Shows whether Gulim (and Batang) still render, and why. Read-only; no admin needed.
.PARAMETER TargetFace
    Font that Gulim should render as. Defaults to Malgun Gothic.
.PARAMETER IncludeBatang
    Also count Batang/Gungsuh in the verdict (they are always listed).
#>
[CmdletBinding()]
param(
    [string]$TargetFace,
    [switch]$IncludeBatang
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
if (-not $TargetFace) { $TargetFace = $DefaultTargetFace }

$targetNames = Get-FamilyNames $TargetFace
if ($targetNames) {
    Write-Host "Target font : $TargetFace ($($targetNames -join ', '))"
} else {
    Write-Host "Target font : $TargetFace  -- NOT INSTALLED" -ForegroundColor Red
}

$fontsDir = Join-Path $env:WINDIR 'Fonts'
$verdictSets = Get-FontSets -IncludeBatang:$IncludeBatang
$problems = 0

foreach ($setName in $FontSets.Keys) {
    $set = $FontSets[$setName]
    $counts = $verdictSets -contains $set
    $present = Test-Path (Join-Path $fontsDir $set.File)
    Write-Host ''
    Write-Host ("[{0}] {1}  file: {2}" -f $setName, $set.File, $(if ($present) { 'present' } else { 'absent' }))

    $entries = @(Get-RegisteredFontEntries $set.File)
    if ($entries) {
        foreach ($entry in $entries) {
            Write-Host "  Registered : $($entry.Name) = $($entry.Data)  (blocks FontSubstitutes)" -ForegroundColor Yellow
        }
    } else {
        Write-Host '  Registered : no'
    }

    Write-Host ('  {0,-12} {1,-20} {2}' -f 'Name', 'Substitute', 'GDI renders as')
    foreach ($name in $set.Names) {
        $substitute = Get-Substitute $name
        $actual = Resolve-GdiFamily $name
        $ok = $targetNames -contains $actual
        if ($counts -and -not $ok) { $problems++ }
        $color = if ($ok) { 'Green' } elseif ($counts) { 'Red' } else { 'Gray' }
        Write-Host ('  {0,-12} {1,-20} {2}' -f $name, $(if ($substitute) { $substitute } else { '-' }), $actual) -ForegroundColor $color
    }
}

Write-Host ''
Add-Type -AssemblyName PresentationCore
$dwrite = @([Windows.Media.Fonts]::SystemFontFamilies | ForEach-Object { $_.Source } |
    Where-Object { $_ -match 'Gulim|Dotum|Batang|Gungsuh' })
Write-Host ("DirectWrite : {0}" -f $(if ($dwrite) { 'still lists ' + ($dwrite -join ', ') } else { 'no Gulim/Batang families' }))

if (Test-Admin) {
    $caps = @(Get-WindowsCapability -Online | Where-Object { $_.Name -like $CapabilityPattern })
    foreach ($cap in $caps) { Write-Host "Capability  : $($cap.Name) = $($cap.State)" }
} else {
    Write-Host 'Capability  : (run elevated to see the Korean Supplemental Fonts state)'
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    $info = $task | Get-ScheduledTaskInfo
    Write-Host "Task        : installed, last run $($info.LastRunTime), result $($info.LastTaskResult)"
} else {
    Write-Host 'Task        : not installed (run Install-Task.ps1 to re-apply after every update)'
}

Write-Host ''
if ($problems -eq 0 -and $targetNames) {
    Write-Host "OK: every checked name renders as $TargetFace." -ForegroundColor Green
} else {
    Write-Host "$problems name(s) do not render as $TargetFace. Run Apply.ps1, then sign out and back in." -ForegroundColor Red
    exit 1
}
