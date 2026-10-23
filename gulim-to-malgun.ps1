<#
.SYNOPSIS
    Makes Gulim (굴림) render as Malgun Gothic (맑은 고딕) and keeps it that way after Windows updates.
.DESCRIPTION
    Menu       (default) Numbered menu with the current patch state at the top.
    Install    Apply the fix now and re-apply it at every startup and sign-in.
    Uninstall  Remove the automation and put back every value this tool changed.
    Status     Show what Gulim renders as right now, and why. Read-only, no admin needed.
    Apply      Apply once without installing anything. The scheduled task runs this.

    Gulim reaches the screen three ways, and Apply closes each one:
    - By name. While gulim.ttc is registered under ...\CurrentVersion\Fonts, GDI and DirectWrite
      hand out the real Gulim for 굴림/Gulim no matter what FontSubstitutes says. Apply removes that
      registration (the file stays on disk) and points every Gulim/Dotum name at the target font.
    - By font linking. FontLink\SystemLink makes Tahoma, Microsoft Sans Serif and others borrow
      missing glyphs (Hanja, kana, sometimes Hangul) from GULIM.TTC by file name. Apply puts the
      target font ahead of Gulim in those chains.
    - By default face. Unknown names fall through to the Korean default face, Gulim, and from there
      through FontSubstitutes, which now points at the target font.
    GDI reads all of this when the session starts, so changes show up after a reboot.
.PARAMETER TargetFace
    Font to render instead. Must be installed for all users. Defaults to Malgun Gothic, or for
    Status and the menu, to the installed one. Font linking always uses Malgun Gothic.
.PARAMETER IncludeBatang
    Also replace Batang, BatangChe, Gungsuh and GungsuhChe (바탕, 궁서).
.PARAMETER RemoveCapability
    Also uninstall the Korean Supplemental Fonts feature, which deletes gulim.ttc and batang.ttc.
    Only done in an interactive Install or Apply, never by the scheduled task. Uninstall
    reinstalls it (needs an internet connection).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\gulim-to-malgun.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\gulim-to-malgun.ps1 Install -IncludeBatang
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Menu', 'Install', 'Uninstall', 'Status', 'Apply')]
    [string]$Action = 'Menu',
    [string]$TargetFace = 'Malgun Gothic',
    [switch]$IncludeBatang,
    [switch]$RemoveCapability,
    [switch]$Quiet,
    [switch]$Elevated
)
$ErrorActionPreference = 'Stop'

# One entry per font file: the file name and every family name it registers (English and Korean).
# This file is saved as UTF-8 with BOM so Windows PowerShell 5.1 reads the Korean names correctly.
$FontSets = [ordered]@{
    Gulim  = @{ File = 'gulim.ttc';  Names = @('Gulim', 'GulimChe', 'Dotum', 'DotumChe', '굴림', '굴림체', '돋움', '돋움체') }
    Batang = @{ File = 'batang.ttc'; Names = @('Batang', 'BatangChe', 'Gungsuh', 'GungsuhChe', '바탕', '바탕체', '궁서', '궁서체') }
}

# Fonts the menu offers as the target. Any font installed for all users works with -TargetFace.
$FaceChoices = @('Malgun Gothic', 'NanumBarunGothic')

# Font linking always borrows from Malgun Gothic, whatever the target: it ships with Windows, covers
# more Hanja than most targets, and switching targets then never rewrites SystemLink again.
$LinkFace = 'Malgun Gothic'

$SubstitutesSubKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes'
$FontsSubKey       = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$SystemLinkSubKey  = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink'
$CapabilityPattern = 'Language.Fonts.Kore*'
$TaskName          = 'gulim-to-malgun'

# Full paths, so nothing earlier on PATH can stand in for them when running as SYSTEM.
$RegExe            = Join-Path $env:SystemRoot 'System32\reg.exe'
$PowerShellExe     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# The installed copy, journal, backups and logs live where only administrators can write,
# because the scheduled task runs the installed copy as SYSTEM.
$InstallDir        = Join-Path $env:ProgramFiles 'gulim-to-malgun'
$InstalledScript   = Join-Path $InstallDir 'gulim-to-malgun.ps1'
$JournalFile       = Join-Path $InstallDir 'original-values.json'
$BackupDir         = Join-Path $InstallDir 'backup'
$LogFile           = Join-Path $InstallDir 'logs\apply.log'
$CapabilityMarker  = Join-Path $InstallDir 'capability-removed.txt'
# What the installed task applies. Readable without admin rights, unlike the task itself.
$SettingsFile      = Join-Path $InstallDir 'settings.json'

# Kept in memory so Install still works after Uninstall deleted the installed copy this runs from.
$SelfText          = [IO.File]::ReadAllText($PSCommandPath)

#region Helpers

function Get-FontSets {
    if ($IncludeBatang) { return @($FontSets.Values) }
    return @($FontSets.Gulim)
}

function Open-HklmKey([string]$SubKey, [switch]$Writable) {
    $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
    return $hklm.OpenSubKey($SubKey, [bool]$Writable)
}

function Get-RegValue([string]$SubKey, [string]$Name) {
    $key = Open-HklmKey $SubKey
    try { return $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames') } finally { $key.Close() }
}

# Values under ...\CurrentVersion\Fonts that point at the given font file.
function Get-RegisteredFontEntries([string]$File) {
    $key = Open-HklmKey $FontsSubKey
    try {
        foreach ($name in $key.GetValueNames()) {
            $data = [string]$key.GetValue($name)
            if ([IO.Path]::GetFileName($data) -ieq $File) { [pscustomobject]@{ Name = $name; Data = $data } }
        }
    } finally { $key.Close() }
}

# All localized family names of an installed font, e.g. 'Malgun Gothic' -> Malgun Gothic, 맑은 고딕.
# Empty when the font is not installed.
function Get-FamilyNames([string]$Face) {
    Add-Type -AssemblyName PresentationCore
    foreach ($family in [Windows.Media.Fonts]::SystemFontFamilies) {
        $names = @($family.FamilyNames.Values)
        if ($names -contains $Face) { return $names }
    }
    return @()
}

# File name of a font installed for all users (HKLM), e.g. 'Malgun Gothic' -> malgun.ttf.
# Per-user fonts don't count: SYSTEM and other accounts can't see them.
function Get-MachineFontFile([string]$Face) {
    $names = @(Get-FamilyNames $Face) + $Face
    $key = Open-HklmKey $FontsSubKey
    try {
        foreach ($valueName in $key.GetValueNames()) {
            # 'Malgun Gothic (TrueType)', 'Gulim & GulimChe & Dotum & DotumChe (TrueType)'
            $families = ($valueName -replace '\s*\([^)]*\)\s*$', '') -split '\s*&\s*'
            foreach ($family in $families) {
                if ($names -contains $family) { return [IO.Path]::GetFileName([string]$key.GetValue($valueName)) }
            }
        }
    } finally { $key.Close() }
    return $null
}

# SystemLink chains that would borrow glyphs from Gulim (or Batang) before $LinkFace,
# with the chain they should have instead: $LinkFace inserted just ahead of the first such entry,
# in the scaled + unscaled pair Windows itself uses for Segoe UI.
function Get-LinkFixes([string]$LinkFile) {
    $blocked = @(Get-FontSets | ForEach-Object { $_.File })
    $key = Open-HklmKey $SystemLinkSubKey
    try {
        foreach ($name in $key.GetValueNames()) {
            if ($name -like "$LinkFace*") { continue }
            if ($key.GetValueKind($name) -ne 'MultiString') { continue }
            $chain = @($key.GetValue($name))
            $blockedAt = -1
            $targetAt = -1
            for ($i = 0; $i -lt $chain.Count; $i++) {
                $file = ($chain[$i] -split ',')[0].Trim()
                if ($blockedAt -lt 0 -and $blocked -contains $file) { $blockedAt = $i }
                if ($targetAt -lt 0 -and $file -ieq $LinkFile) { $targetAt = $i }
            }
            if ($blockedAt -lt 0) { continue }
            if ($targetAt -ge 0 -and $targetAt -lt $blockedAt) { continue }

            $fixed = New-Object System.Collections.Generic.List[string]
            for ($i = 0; $i -lt $chain.Count; $i++) {
                if ($i -eq $blockedAt) {
                    $fixed.Add("$($LinkFile.ToUpper()),$LinkFace,128,96")
                    $fixed.Add("$($LinkFile.ToUpper()),$LinkFace")
                }
                $fixed.Add($chain[$i])
            }
            [pscustomobject]@{ Name = $name; Blocked = $chain[$blockedAt]; Chain = [string[]]$fixed.ToArray() }
        }
    } finally { $key.Close() }
}

# Family name of the font GDI actually loads for a requested face, after FontSubstitutes.
# Read from the loaded font's name table, so it reports the real font rather than the request.
# GDI reads its tables when the session starts, so this reflects the registry as of the last sign-in.
function Resolve-GdiFamily([string]$Face) {
    if (-not ('GulimToMalgun.Gdi' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace GulimToMalgun {
  public static class Gdi {
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFontW(int h, int w, int esc, int orient, int weight, uint italic, uint underline,
        uint strike, uint charset, uint outPrec, uint clipPrec, uint quality, uint pitchFamily, string face);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern uint GetOutlineTextMetricsW(IntPtr dc, uint size, IntPtr buffer);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct TEXTMETRICW { public int a, b, c, d, e, f, g, h, i, j, k; public char l, m, n, o; public byte p, q, r, s, t; }
    [StructLayout(LayoutKind.Sequential)] struct PANOSE { public byte a, b, c, d, e, f, g, h, i, j; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)]
    struct OUTLINETEXTMETRICW {
      public uint otmSize; public TEXTMETRICW otmTextMetrics; public byte otmFiller; public PANOSE otmPanoseNumber;
      public uint otmfsSelection, otmfsType; public int otmsCharSlopeRise, otmsCharSlopeRun, otmItalicAngle;
      public uint otmEMSquare; public int otmAscent, otmDescent; public uint otmLineGap, otmsCapEmHeight, otmsXHeight;
      public RECT otmrcFontBox; public int otmMacAscent, otmMacDescent; public uint otmMacLineGap, otmusMinimumPPEM;
      public POINT otmptSubscriptSize, otmptSubscriptOffset, otmptSuperscriptSize, otmptSuperscriptOffset;
      public uint otmsStrikeoutSize; public int otmsStrikeoutPosition, otmsUnderscoreSize, otmsUnderscorePosition;
      public IntPtr otmpFamilyName, otmpFaceName, otmpStyleName, otmpFullName;
    }

    public static string Resolve(string face) {
      IntPtr dc = CreateCompatibleDC(IntPtr.Zero);
      IntPtr font = CreateFontW(-16, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 0, 0, face);
      IntPtr old = SelectObject(dc, font);
      string result = null;
      uint size = GetOutlineTextMetricsW(dc, 0, IntPtr.Zero);
      if (size > 0) {
        IntPtr buffer = Marshal.AllocHGlobal((int)size);
        if (GetOutlineTextMetricsW(dc, size, buffer) > 0) {
          // otmpFamilyName holds an offset from the start of the buffer, not a pointer.
          int field = (int)Marshal.OffsetOf(typeof(OUTLINETEXTMETRICW), "otmpFamilyName");
          long offset = Marshal.ReadIntPtr(buffer, field).ToInt64();
          result = Marshal.PtrToStringUni(new IntPtr(buffer.ToInt64() + offset));
        }
        Marshal.FreeHGlobal(buffer);
      }
      SelectObject(dc, old);
      DeleteObject(font);
      DeleteDC(dc);
      return result;
    }
  }
}
'@
    }
    return [GulimToMalgun.Gdi]::Resolve($Face)
}

# The target and scope the installed task applies, or $null when not installed.
# Installs from before settings.json only have the task's arguments, which need admin rights to read.
function Get-InstalledOptions {
    if (Test-Path $SettingsFile) {
        $settings = Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{ TargetFace = [string]$settings.TargetFace; IncludeBatang = [bool]$settings.IncludeBatang }
    }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return $null }
    $arguments = $task.Actions[0].Arguments
    [pscustomobject]@{
        TargetFace    = $(if ($arguments -match '-TargetFace "([^"]+)"') { $Matches[1] } else { 'Malgun Gothic' })
        IncludeBatang = $arguments -match '-IncludeBatang'
    }
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Re-runs this script in an elevated window with the same arguments plus -Elevated.
# Returns the elevated run's exit code, or 1 when the administrator prompt is declined.
function Invoke-Elevated {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", $Action, '-Elevated',
        '-TargetFace', "`"$TargetFace`"")
    if ($IncludeBatang) { $argList += '-IncludeBatang' }
    if ($RemoveCapability) { $argList += '-RemoveCapability' }
    Write-Host 'Administrator rights are needed; opening an elevated window...'
    try {
        $process = Start-Process $PowerShellExe -Verb RunAs -ArgumentList $argList -Wait -PassThru
        return $process.ExitCode
    } catch {
        Write-Host 'Cancelled: administrator rights were not granted.' -ForegroundColor Yellow
        return 1
    }
}

function Write-Log([string]$Message) {
    $dir = Split-Path $LogFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Content -Path $LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) -Encoding UTF8
    if (-not $Quiet) { Write-Host $Message }
}

# Runs reg.exe outside PowerShell's stream handling: it prints success messages to stderr,
# which Windows PowerShell 5.1 turns into terminating errors under ErrorActionPreference Stop.
function Invoke-Reg([string[]]$Arguments) {
    $quoted = $Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }
    $process = Start-Process $RegExe -ArgumentList $quoted -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) { throw "reg.exe $($Arguments -join ' ') failed with exit code $($process.ExitCode)" }
}

#endregion

#region Journal
# original-values.json holds, for every registry value this tool has changed, what it was before the
# first change. Each entry is written before the change it describes, so Uninstall can put back
# exactly those values even after a run that failed half-way.

function Read-Journal {
    $journal = [ordered]@{}
    if (Test-Path $JournalFile) {
        foreach ($entry in (Get-Content $JournalFile -Raw -Encoding UTF8 | ConvertFrom-Json)) {
            $journal["$($entry.Key)|$($entry.Name)"] = $entry
        }
    }
    return $journal
}

function Save-Journal($Journal) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $temp = "$JournalFile.tmp"
    $json = ConvertTo-Json -InputObject @($Journal.Values) -Depth 5
    [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding $false))
    Move-Item $temp $JournalFile -Force
}

# Records a value's current state in the journal unless an earlier change already did.
function Save-Original($Journal, [string]$SubKey, [string]$Name) {
    if ($Journal.Contains("$SubKey|$Name")) { return }
    $key = Open-HklmKey $SubKey
    try {
        $existed = $key.GetValueNames() -contains $Name
        $Journal["$SubKey|$Name"] = [pscustomobject]@{
            Key     = $SubKey
            Name    = $Name
            Existed = $existed
            Kind    = $(if ($existed) { [string]$key.GetValueKind($Name) } else { $null })
            Data    = $(if ($existed) { $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames') } else { $null })
        }
    } finally { $key.Close() }
    Save-Journal $Journal
}

function Set-JournaledValue($Journal, [string]$SubKey, [string]$Name, $Data, [string]$Kind) {
    Save-Original $Journal $SubKey $Name
    $key = Open-HklmKey $SubKey -Writable
    try { $key.SetValue($Name, $Data, $Kind) } finally { $key.Close() }
}

function Remove-JournaledValue($Journal, [string]$SubKey, [string]$Name) {
    Save-Original $Journal $SubKey $Name
    $key = Open-HklmKey $SubKey -Writable
    try { $key.DeleteValue($Name, $false) } finally { $key.Close() }
}

#endregion

#region Actions

function Invoke-Apply {
    $targetFile = Get-MachineFontFile $TargetFace
    if (-not $targetFile) { throw "Target font '$TargetFace' is not installed for all users." }

    $steps = @()
    foreach ($set in Get-FontSets) {
        foreach ($name in $set.Names) {
            $current = Get-RegValue $SubstitutesSubKey $name
            if ($current -ne $TargetFace) { $steps += [pscustomobject]@{ Kind = 'Substitute'; Name = $name; From = $current } }
        }
        foreach ($entry in Get-RegisteredFontEntries $set.File) {
            $steps += [pscustomobject]@{ Kind = 'Unregister'; Name = $entry.Name; From = $entry.Data }
        }
    }
    $linkFile = Get-MachineFontFile $LinkFace
    foreach ($fix in $(if ($linkFile) { Get-LinkFixes $linkFile })) {
        $steps += [pscustomobject]@{ Kind = 'Link'; Name = $fix.Name; From = $fix.Blocked; Chain = $fix.Chain }
    }

    # Removing a Windows feature can take minutes; never do it from the startup task.
    $capabilities = @()
    if ($RemoveCapability -and -not $Quiet) {
        $capabilities = @(Get-WindowsCapability -Online |
            Where-Object { $_.Name -like $CapabilityPattern -and $_.State -eq 'Installed' })
    }

    if (-not $steps -and -not $capabilities) {
        if (-not $Quiet) { Write-Host "Already applied: nothing to change." }
        return $false
    }

    # Whole-key exports from before the first change, for manual recovery only.
    if (-not (Test-Path $BackupDir)) {
        $temp = "$BackupDir.tmp"
        if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        foreach ($pair in @(@('FontSubstitutes', $SubstitutesSubKey), @('Fonts', $FontsSubKey), @('SystemLink', $SystemLinkSubKey))) {
            Invoke-Reg @('export', "HKLM\$($pair[1])", (Join-Path $temp "original-$($pair[0]).reg"), '/y', '/reg:64')
        }
        Move-Item $temp $BackupDir
    }

    $journal = Read-Journal
    foreach ($step in $steps) {
        switch ($step.Kind) {
            'Substitute' {
                Set-JournaledValue $journal $SubstitutesSubKey $step.Name $TargetFace 'String'
                Write-Log "Substitute  $($step.Name): '$($step.From)' -> '$TargetFace'"
            }
            'Unregister' {
                Remove-JournaledValue $journal $FontsSubKey $step.Name
                Write-Log "Unregister  $($step.Name) = $($step.From)"
            }
            'Link' {
                Set-JournaledValue $journal $SystemLinkSubKey $step.Name $step.Chain 'MultiString'
                Write-Log "Link        $($step.Name): $LinkFace ahead of $($step.From)"
            }
        }
    }

    foreach ($capability in $capabilities) {
        # Marker first, so Uninstall reinstalls it even if removal fails half-way.
        Add-Content -Path $CapabilityMarker -Value $capability.Name -Encoding UTF8
        Write-Log "Removing capability $($capability.Name)..."
        Remove-WindowsCapability -Online -Name $capability.Name | Out-Null
        Write-Log "Removed capability $($capability.Name)"
    }
    return $true
}

function Invoke-Install {
    $changed = Invoke-Apply

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    [IO.File]::WriteAllText($InstalledScript, $SelfText, (New-Object Text.UTF8Encoding $true))

    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstalledScript`" Apply -Quiet -TargetFace `"$TargetFace`""
    if ($IncludeBatang) { $arguments += ' -IncludeBatang' }

    $action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $arguments
    $triggers = @(New-ScheduledTaskTrigger -AtStartup; New-ScheduledTaskTrigger -AtLogOn)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal `
        -Settings $settings -Description "Keeps Gulim rendering as $TargetFace after Windows updates." -Force | Out-Null
    $json = ConvertTo-Json @{ TargetFace = $TargetFace; IncludeBatang = [bool]$IncludeBatang }
    [IO.File]::WriteAllText($SettingsFile, $json, (New-Object Text.UTF8Encoding $false))

    Write-Host ''
    Write-Host 'Installed. The fix is re-applied automatically at every startup and sign-in.' -ForegroundColor Green
    if ($changed) { Write-Host 'Reboot so Windows and running apps pick up the change.' }
}

function Invoke-Uninstall {
    # Feature first: if it can't come back, leave everything else (and the task) as it is,
    # rather than re-registering a font file that no longer exists.
    if (Test-Path $CapabilityMarker) {
        foreach ($name in Get-Content $CapabilityMarker -Encoding UTF8 | Where-Object { $_ } | Select-Object -Unique) {
            $capability = Get-WindowsCapability -Online -Name $name
            if ($capability.State -ne 'Installed') {
                Write-Host "Reinstalling $name (needs an internet connection)..."
                Add-WindowsCapability -Online -Name $name | Out-Null
            }
        }
    }

    $journal = Read-Journal
    $fontsDir = Join-Path $env:SystemRoot 'Fonts'
    foreach ($entry in @($journal.Values)) {
        $key = Open-HklmKey $entry.Key -Writable
        try {
            if (-not $entry.Existed) {
                $key.DeleteValue($entry.Name, $false)
            } elseif ($entry.Key -eq $FontsSubKey -and -not (Test-Path (Join-Path $fontsDir ([IO.Path]::GetFileName([string]$entry.Data))))) {
                Write-Host "Skipped re-registering $($entry.Name): $($entry.Data) is not in $fontsDir." -ForegroundColor Yellow
            } else {
                # Not '$data = if ...': that unrolls the array into Object[], which SetValue rejects for MultiString.
                $data = $entry.Data
                if ($entry.Kind -eq 'MultiString') { $data = [string[]]@($entry.Data) }
                $key.SetValue($entry.Name, $data, [Microsoft.Win32.RegistryValueKind]$entry.Kind)
            }
        } finally { $key.Close() }
    }
    if ($journal.Count) {
        Write-Host "Restored $($journal.Count) registry value(s) to how they were before the first change."
    } else {
        Write-Host 'Nothing to restore.'
    }

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'."
    }

    # Stay out of the folder being deleted when the installed copy itself is running.
    Set-Location $env:SystemRoot
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
    Write-Host 'Uninstalled. Reboot for the change to take effect.' -ForegroundColor Green
}

# Whether the registry is fixed, and whether GDI in this session already renders the target font.
# The registry can be fixed while rendering is not, until the next reboot.
function Get-PatchState {
    $targetNames = Get-FamilyNames $TargetFace
    $targetFile = Get-MachineFontFile $TargetFace
    $registryOk = [bool]$targetFile
    $renderOk = [bool]$targetNames
    foreach ($set in Get-FontSets) {
        if (@(Get-RegisteredFontEntries $set.File)) { $registryOk = $false }
        foreach ($name in $set.Names) {
            if ((Get-RegValue $SubstitutesSubKey $name) -ne $TargetFace) { $registryOk = $false }
            if ($targetNames -notcontains (Resolve-GdiFamily $name)) { $renderOk = $false }
        }
    }
    $linkFile = Get-MachineFontFile $LinkFace
    if ($linkFile -and @(Get-LinkFixes $linkFile)) { $registryOk = $false }
    [pscustomobject]@{
        RegistryOk = $registryOk
        RenderOk   = $renderOk -and $registryOk
        Task       = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
}

function Show-Status {
    $targetNames = Get-FamilyNames $TargetFace
    $targetFile = Get-MachineFontFile $TargetFace
    if ($targetFile) {
        Write-Host "Target font : $TargetFace ($($targetNames -join ', ')) = $targetFile"
    } else {
        Write-Host "Target font : $TargetFace  -- NOT INSTALLED FOR ALL USERS" -ForegroundColor Red
    }

    $fontsDir = Join-Path $env:SystemRoot 'Fonts'
    $verdictSets = Get-FontSets
    $problems = 0

    foreach ($setName in $FontSets.Keys) {
        $set = $FontSets[$setName]
        $counts = $verdictSets -contains $set
        $present = Test-Path (Join-Path $fontsDir $set.File)
        Write-Host ''
        Write-Host ("[{0}] {1}  file: {2}" -f $setName, $set.File, $(if ($present) { 'present' } else { 'absent' }))

        $entries = @(Get-RegisteredFontEntries $set.File)
        if ($entries) {
            if ($counts) { $problems++ }
            foreach ($entry in $entries) {
                Write-Host "  Registered : $($entry.Name) = $($entry.Data)  (wins over substitutes)" -ForegroundColor $(if ($counts) { 'Yellow' } else { 'Gray' })
            }
        } else {
            Write-Host '  Registered : no'
        }

        Write-Host ('  {0,-12} {1,-20} {2}' -f 'Name', 'Substitute', 'GDI renders as (this session)')
        foreach ($name in $set.Names) {
            $substitute = Get-RegValue $SubstitutesSubKey $name
            $actual = Resolve-GdiFamily $name
            $ok = $targetNames -contains $actual
            if ($counts -and -not $ok) { $problems++ }
            $color = if ($ok) { 'Green' } elseif ($counts) { 'Red' } else { 'Gray' }
            Write-Host ('  {0,-12} {1,-20} {2}' -f $name, $(if ($substitute) { $substitute } else { '-' }), $actual) -ForegroundColor $color
        }
    }

    Write-Host ''
    $linkFile = Get-MachineFontFile $LinkFace
    if ($linkFile) {
        $links = @(Get-LinkFixes $linkFile)
        if ($links) {
            $problems += $links.Count
            Write-Host "SystemLink  : $($links.Count) chain(s) borrow glyphs from Gulim/Batang before ${LinkFace}:" -ForegroundColor Yellow
            Write-Host "              $(($links | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Yellow
        } else {
            Write-Host "SystemLink  : $LinkFace comes before Gulim in every chain"
        }
    }

    Add-Type -AssemblyName PresentationCore
    $dwrite = @([Windows.Media.Fonts]::SystemFontFamilies | ForEach-Object { $_.Source } |
        Where-Object { $_ -match 'Gulim|Dotum|Batang|Gungsuh' })
    Write-Host ("DirectWrite : {0}" -f $(if ($dwrite) { 'still lists ' + ($dwrite -join ', ') + ' (Chrome, Edge, Office can use them)' } else { 'no Gulim/Batang families' }))

    # Without admin rights a task running as SYSTEM can't be read, so it looks the same as no task.
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = $task | Get-ScheduledTaskInfo
        Write-Host "Automation  : installed, last run $($info.LastRunTime), result $($info.LastTaskResult)"
    } elseif (Test-Admin) {
        Write-Host 'Automation  : not installed'
    } elseif (Test-Path $SettingsFile) {
        Write-Host 'Automation  : installed (run as administrator for the last run time)'
    } else {
        Write-Host 'Automation  : unknown (run as administrator to check)'
    }

    Write-Host ''
    if ($problems -eq 0 -and $targetFile) {
        Write-Host "OK: Gulim is replaced by $TargetFace everywhere this tool can check." -ForegroundColor Green
        return 0
    }
    Write-Host "$problems problem(s) found. If you just installed, reboot first." -ForegroundColor Red
    return 1
}

# Lists $FaceChoices with whether each is installed for all users, and returns the one picked
# ($null for Back, or for a font the scheduled task could not use).
function Select-TargetFace {
    Write-Host '  Render Gulim as:'
    for ($i = 0; $i -lt $FaceChoices.Count; $i++) {
        $face = $FaceChoices[$i]
        $names = @(Get-FamilyNames $face)
        $state = if (Get-MachineFontFile $face) { 'installed' }
                 elseif ($names) { 'installed for this user only' }
                 else { 'not installed' }
        if ($face -eq $TargetFace) { $state += ', current' }
        $localName = $names | Where-Object { $_ -ne $face } | Select-Object -First 1
        Write-Host ('  [{0}] {1,-18} {2,-34} {3}' -f ($i + 1), $face, $state, $localName) `
            -ForegroundColor $(if ($state -like 'installed*' -and $state -notlike '*user only*') { 'Gray' } else { 'DarkGray' })
    }
    Write-Host '  [0] Back'
    Write-Host ''
    $choice = Read-Host '  Select'
    $index = 0
    if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $FaceChoices.Count) { return $null }
    $face = $FaceChoices[$index - 1]
    if (-not (Get-MachineFontFile $face)) {
        Write-Host ''
        Write-Host "  $face is not installed for all users, so the startup task could not use it." -ForegroundColor Yellow
        Write-Host '  Install it first: right-click the .ttf file > Show more options > Install for all users.' -ForegroundColor Yellow
        return $null
    }
    return $face
}

function Show-Menu {
    $requestedBatang = [bool]$IncludeBatang
    $requestedFace = $TargetFace
    while ($true) {
        Clear-Host
        # Judge the patch by what is installed: Batang counts only if the task replaces it too.
        $installed = Get-InstalledOptions
        if ($installed) {
            $script:IncludeBatang = $installed.IncludeBatang
            $script:TargetFace = $installed.TargetFace
        } else {
            $script:IncludeBatang = $requestedBatang
            $script:TargetFace = $requestedFace
        }
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $scope = if ($IncludeBatang) { 'Gulim + Batang/Gungsuh' } else { 'Gulim' }
        $state = Get-PatchState
        Write-Host "  gulim-to-malgun  |  $scope -> $TargetFace"
        Write-Host '  ------------------------------------------------'
        if ($state.RenderOk) {
            Write-Host "  Patch      : Applied - $scope renders as $TargetFace" -ForegroundColor Green
        } elseif ($state.RegistryOk) {
            Write-Host '  Patch      : Applied - reboot to take effect' -ForegroundColor Yellow
        } else {
            Write-Host "  Patch      : Not applied - $scope renders as the original font" -ForegroundColor Red
        }
        if ($state.Task) {
            $info = $state.Task | Get-ScheduledTaskInfo
            Write-Host "  Automation : Installed - $scope (last run $($info.LastRunTime))" -ForegroundColor Green
        } else {
            Write-Host '  Automation : Not installed - Gulim may come back after Windows updates' -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host '  [1] Install - Gulim only             Apply now and re-apply after every update'
        Write-Host '  [2] Install - Gulim + Batang/Gungsuh Same, and replace Batang/Gungsuh too'
        Write-Host '  [3] Status                           Show what each name and fallback actually uses'
        Write-Host '  [4] Uninstall                        Remove automation and restore the original state'
        Write-Host ('  [5] Font - {0,-26} Choose the font Gulim renders as' -f $TargetFace)
        Write-Host '  [0] Exit'
        Write-Host ''
        $choice = Read-Host '  Select'
        if ($choice -eq '0' -or $choice -eq '') { return }
        if ($choice -notin '1', '2', '3', '4', '5') { continue }

        Write-Host ''
        try {
            switch ($choice) {
                '1' {
                    # Switching from Gulim + Batang back to Gulim only: start from the original state
                    # so Batang is not left replaced without the task maintaining it.
                    if ($IncludeBatang -and $installed) { Invoke-Uninstall; Write-Host '' }
                    $script:IncludeBatang = $false
                    Invoke-Install
                }
                '2' { $script:IncludeBatang = $true; Invoke-Install }
                '3' { [void](Show-Status) }
                '4' {
                    if ((Read-Host '  Remove automation and restore the original state? (y/N)') -eq 'y') { Invoke-Uninstall }
                }
                '5' {
                    $face = Select-TargetFace
                    if ($face -and $face -ne $TargetFace) {
                        $requestedFace = $face
                        $script:TargetFace = $face
                        # Installed: switch now, keeping the scope. Only FontSubstitutes changes;
                        # the journal already holds the values from before the first change.
                        if ($installed) {
                            Write-Host ''
                            Invoke-Install
                        } else {
                            Write-Host ''
                            Write-Host "  $face selected. Install with [1] or [2] to apply it."
                        }
                    }
                }
            }
        } catch {
            if (Test-Path (Split-Path $LogFile -Parent)) { Add-Content -Path $LogFile -Value "ERROR $_" -Encoding UTF8 }
            Write-Host "ERROR: $_" -ForegroundColor Red
        }
        Write-Host ''
        [void](Read-Host '  Press Enter to return to the menu')
    }
}

#endregion

if ($Action -eq 'Status') {
    # Check what is installed, unless the command line asks about something else.
    $installed = Get-InstalledOptions
    if ($installed -and -not $PSBoundParameters.ContainsKey('TargetFace')) { $TargetFace = $installed.TargetFace }
    if ($installed -and -not $PSBoundParameters.ContainsKey('IncludeBatang')) { $IncludeBatang = [switch]$installed.IncludeBatang }
    exit (Show-Status)
}

if (-not (Test-Admin)) {
    if ($Quiet) { Write-Error "$Action -Quiet must run elevated."; exit 1 }
    exit (Invoke-Elevated)
}

$exitCode = 0
try {
    switch ($Action) {
        'Menu'      { Show-Menu }
        'Install'   { Invoke-Install }
        'Uninstall' { Invoke-Uninstall }
        'Apply'     {
            if ((Invoke-Apply) -and -not $Quiet) { Write-Host 'Reboot so Windows and running apps pick up the change.' }
        }
    }
} catch {
    $exitCode = 1
    if (Test-Path (Split-Path $LogFile -Parent)) { Add-Content -Path $LogFile -Value "ERROR $_" -Encoding UTF8 }
    Write-Host "ERROR: $_" -ForegroundColor Red
} finally {
    # Keep an elevated window open so its output can be read; the menu waits on its own.
    if ($Elevated -and ($Action -ne 'Menu' -or $exitCode -ne 0)) { [void](Read-Host 'Press Enter to close') }
}
exit $exitCode
