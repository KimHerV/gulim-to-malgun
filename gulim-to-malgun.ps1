<#
.SYNOPSIS
    Makes Gulim (굴림) render as Malgun Gothic (맑은 고딕) and keeps it that way after Windows updates.
.DESCRIPTION
    Menu       (default) Numbered menu with the current patch state at the top.
    Install    Apply the fix now and re-apply it at every startup and sign-in.
    Uninstall  Remove the automation and put back every value this tool changed.
    Status     Show what Gulim renders as right now, and why. Read-only, no admin needed.
    Test       Open a window that draws the same line through every way Gulim can appear. No admin needed.
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
.PARAMETER OutFile
    Test only: save the test image to this PNG file instead of opening a window.
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
    [ValidateSet('Menu', 'Install', 'Uninstall', 'Status', 'Test', 'Apply')]
    [string]$Action = 'Menu',
    # No quotes or backslashes: the name is passed on the scheduled task's command line.
    [ValidatePattern('^[^"\\]+$')]
    [string]$TargetFace = 'Malgun Gothic',
    [switch]$IncludeBatang,
    [switch]$RemoveCapability,
    [string]$OutFile,
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

# The default target, always listed first in the menu. The menu also lists every other font that is
# installed for all users and covers Hangul; -TargetFace accepts any such font.
$DefaultFace = 'Malgun Gothic'

# Font linking always borrows from Malgun Gothic, whatever the target: it ships with Windows, covers
# more Hanja than most targets, and switching targets then never rewrites SystemLink again.
$LinkFace = 'Malgun Gothic'

$SubstitutesSubKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes'
$FontsSubKey       = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$SystemLinkSubKey  = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink'
$CapabilityPattern = 'Language.Fonts.Kore*'
$TaskName          = 'gulim-to-malgun'

# Full paths, so nothing earlier on PATH can stand in for them when running as SYSTEM. Folders come
# from Windows itself rather than environment variables, which the user's own registry can override.
$SystemDir         = [Environment]::GetFolderPath('System')
$FontsDir          = [Environment]::GetFolderPath('Fonts')
$RegExe            = Join-Path $SystemDir 'reg.exe'
$PowerShellExe     = Join-Path $SystemDir 'WindowsPowerShell\v1.0\powershell.exe'

# The installed copy, journal, backups and logs live where only administrators can write,
# because the scheduled task runs the installed copy as SYSTEM.
$InstallDir        = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'gulim-to-malgun'
$InstalledScript   = Join-Path $InstallDir 'gulim-to-malgun.ps1'
$JournalFile       = Join-Path $InstallDir 'original-values.json'
$BackupDir         = Join-Path $InstallDir 'backup'
$LogFile           = Join-Path $InstallDir 'logs\apply.log'
$CapabilityMarker  = Join-Path $InstallDir 'capability-removed.txt'
# What the installed task applies. Readable without admin rights, unlike the task itself.
$SettingsFile      = Join-Path $InstallDir 'settings.json'

# Kept in memory so Install still works after Uninstall deleted the installed copy this runs from.
$SelfText          = [IO.File]::ReadAllText($PSCommandPath)

$RestartHint       = 'Restart Windows to see the change.'

# Optional console font setting (menu item 7). These are the current user's console settings, so the
# originals go in a per-user journal rather than the machine one.
$ConsoleKeys       = @('Console',
                       'Console\%SystemRoot%_System32_WindowsPowerShell_v1.0_powershell.exe',
                       'Console\%SystemRoot%_SysWOW64_WindowsPowerShell_v1.0_powershell.exe')
$ConsoleValues     = @('FaceName', 'FontFamily', 'FontSize', 'FontWeight', 'CodePage')
$ConsoleFaces      = @('Cascadia Mono', 'Consolas')
$ConsoleJournal    = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'gulim-to-malgun\console-original.json'

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
    if (-not $key) { return $null }
    try { return $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames') } finally { $key.Close() }
}

# Last part of a path or a font-link entry's file field. Unlike [IO.Path]::GetFileName it never
# throws, whatever other software has written into these values.
function Get-LeafName([string]$Path) {
    return ($Path.Trim() -split '[\\/]')[-1]
}

# Values under ...\CurrentVersion\Fonts that point at the given font file.
function Get-RegisteredFontEntries([string]$File) {
    $key = Open-HklmKey $FontsSubKey
    if (-not $key) { return }
    try {
        foreach ($name in $key.GetValueNames()) {
            $data = [string]$key.GetValue($name)
            if ((Get-LeafName $data) -ieq $File) { [pscustomobject]@{ Name = $name; Data = $data } }
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
    if (-not $key) { return $null }
    try {
        foreach ($valueName in $key.GetValueNames()) {
            # 'Malgun Gothic (TrueType)', 'Gulim & GulimChe & Dotum & DotumChe (TrueType)'
            $families = ($valueName -replace '\s*\([^)]*\)\s*$', '') -split '\s*&\s*'
            foreach ($family in $families) {
                if ($names -contains $family) { return Get-LeafName ([string]$key.GetValue($valueName)) }
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
    if (-not $key) { return }
    try {
        foreach ($name in $key.GetValueNames()) {
            if ($name -like "$LinkFace*") { continue }
            if ($key.GetValueKind($name) -ne 'MultiString') { continue }
            $chain = @($key.GetValue($name))
            $blockedAt = -1
            $targetAt = -1
            for ($i = 0; $i -lt $chain.Count; $i++) {
                # 'GULIM.TTC,Gulim' or, rarely, a full path before the comma.
                $file = Get-LeafName ($chain[$i] -split ',')[0]
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
        try {
            $settings = Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($settings.TargetFace) {
                return [pscustomobject]@{ TargetFace = [string]$settings.TargetFace; IncludeBatang = [bool]$settings.IncludeBatang }
            }
        } catch { }   # Unreadable: fall back to the task's arguments below.
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

# Names the script, its folder or the launcher if anyone but this user, administrators, SYSTEM or
# TrustedInstaller can change them. Running such a copy as administrator (and installing it to run
# as SYSTEM) would run whatever that account put there. An allow-list, because sandbox and service
# accounts get write access to user folders too, not only the well-known groups.
function Get-UnsafeSourcePaths([string]$ScriptPath = $PSCommandPath) {
    $trusted = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        'S-1-5-18',      # SYSTEM
        'S-1-5-32-544',  # Administrators
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'  # TrustedInstaller
    )
    $fileRights = [Security.AccessControl.FileSystemRights]'WriteData, AppendData, Delete, ChangePermissions, TakeOwnership'
    $folderRights = [Security.AccessControl.FileSystemRights]'CreateFiles, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    $folder = Split-Path $ScriptPath -Parent
    $checks = @(@($ScriptPath, $fileRights), @($folder, $folderRights))
    $launcher = Join-Path $folder 'gulim-to-malgun.cmd'
    if (Test-Path $launcher) { $checks += , @($launcher, $fileRights) }
    foreach ($check in $checks) {
        $acl = Get-Acl $check[0]
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        $writers = @(foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            # Inherit-only entries apply to children, not to this file or folder.
            if ($rule.AccessControlType -ne 'Allow' -or $rule.PropagationFlags -band 'InheritOnly') { continue }
            if ($rule.FileSystemRights -band $check[1]) { $rule.IdentityReference.Value }
        })
        # The owner can always change permissions, so it has to be trusted too.
        if (@($writers + $owner | Where-Object { $trusted -notcontains $_ }).Count) { $check[0] }
    }
}

function Assert-SafeSource {
    $unsafe = @(Get-UnsafeSourcePaths)
    if (-not $unsafe) { return }
    throw ("Other accounts on this PC can change $($unsafe -join ', '). Running it as administrator would run " +
        "whatever they put there. Run gulim-to-malgun.cmd without administrator rights and let it make a " +
        "protected copy, or put the folder somewhere only you and administrators can change.")
}

# A copy of this tool in a folder only this user, administrators and SYSTEM can change (inherited
# permissions removed), for when the folder it was started from is open to other accounts.
# Returns the copied script's path.
function New-ProtectedCopy {
    $target = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'gulim-to-malgun\source'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in [Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544') {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule (
            (New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    # Not Set-Acl: it can try to write the audit (SACL) part too, which needs a privilege users lack.
    (Get-Item $target).SetAccessControl($acl)
    $folder = Split-Path $PSCommandPath -Parent
    foreach ($name in 'gulim-to-malgun.ps1', 'gulim-to-malgun.cmd', 'README.md') {
        $source = Join-Path $folder $name
        $destination = Join-Path $target $name
        if (Test-Path $destination) { Remove-Item $destination -Force }   # a fresh file inherits the new permissions
        if (Test-Path $source) { Copy-Item $source $destination }
    }
    return Join-Path $target 'gulim-to-malgun.ps1'
}

# Re-runs this script in an elevated window with the same arguments plus -Elevated.
# Returns the elevated run's exit code, or 1 when the administrator prompt is declined.
function Invoke-Elevated {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", $Action, '-Elevated',
        '-TargetFace', "`"$TargetFace`"")
    if ($IncludeBatang) { $argList += '-IncludeBatang' }
    if ($RemoveCapability) { $argList += '-RemoveCapability' }
    Write-Host 'Opening gulim-to-malgun in an administrator window. This window closes when that one does.'
    try {
        $process = Start-Process $PowerShellExe -Verb RunAs -ArgumentList $argList -Wait -PassThru
        return $process.ExitCode
    } catch {
        Write-Host 'Cancelled: administrator rights were not granted. Run it again and choose Yes.' -ForegroundColor Yellow
        return 1
    }
}

# Errors go to the log with a timestamp, also when the task runs it with -Quiet.
function Write-ErrorLog($ErrorRecord) {
    try {
        $dir = Split-Path $LogFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss} ERROR {1}' -f (Get-Date), $ErrorRecord) -Encoding UTF8
    } catch { }   # Not admin, or the folder is gone: the message is still shown.
}

function Write-ErrorHelp($ErrorRecord) {
    Write-Host "ERROR: $ErrorRecord" -ForegroundColor Red
    Write-Host 'Some changes may already have been made. Choose [3] Status to see where things stand, or [4] to'
    Write-Host "restore everything. Details are in $LogFile."
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

# Puts the given journal entries back and removes them from $Journal (the caller saves it).
# Entries that can't be put back yet stay in the journal and are returned as skipped. Only the
# three font keys and their value types are accepted, whatever the file says.
function Restore-JournalEntries($Journal, $Entries) {
    $allowedKeys = @($SubstitutesSubKey, $FontsSubKey, $SystemLinkSubKey)
    $restored = 0
    $skipped = @()
    foreach ($entry in @($Entries)) {
        $reason = $null
        if ($allowedKeys -notcontains $entry.Key) {
            $reason = 'not a key this tool changes'
        } elseif ($entry.Existed -and @('String', 'ExpandString', 'MultiString') -notcontains $entry.Kind) {
            $reason = "unexpected value type '$($entry.Kind)'"
        } elseif ($entry.Existed -and $entry.Key -eq $FontsSubKey) {
            $data = [string]$entry.Data
            $file = Get-LeafName $data
            if ($data -ne $file -and -not $data.StartsWith("$FontsDir\", [StringComparison]::OrdinalIgnoreCase)) {
                $reason = "unexpected font path '$data'"
            } elseif (-not (Test-Path (Join-Path $FontsDir $file))) {
                $reason = "$file is not in $FontsDir"
            }
        }
        if (-not $reason) {
            $key = Open-HklmKey $entry.Key -Writable
            if (-not $key) {
                $reason = 'the registry key is missing'
            } else {
                try {
                    if (-not $entry.Existed) {
                        $key.DeleteValue($entry.Name, $false)
                    } else {
                        # Not '$data = if ...': that unrolls the array into Object[], which SetValue rejects for MultiString.
                        $data = $entry.Data
                        if ($entry.Kind -eq 'MultiString') { $data = [string[]]@($entry.Data) }
                        $key.SetValue($entry.Name, $data, [Microsoft.Win32.RegistryValueKind]$entry.Kind)
                    }
                } finally { $key.Close() }
            }
        }
        if ($reason) {
            $skipped += [pscustomobject]@{ Name = $entry.Name; Reason = $reason }
        } else {
            $restored++
            $Journal.Remove("$($entry.Key)|$($entry.Name)")
        }
    }
    [pscustomobject]@{ Restored = $restored; Skipped = $skipped }
}

function Write-Skipped($Skipped) {
    foreach ($item in $Skipped) { Write-Host "  Not put back yet: $($item.Name) ($($item.Reason))" -ForegroundColor Yellow }
}

# Puts back only what this tool changed for one font set, e.g. Batang when the scope shrinks to
# Gulim only. A font-link chain that also had Gulim in it is restored too; Apply then fixes it for
# Gulim again.
function Restore-FontSet($Set, [string]$Label) {
    $journal = Read-Journal
    $entries = @($journal.Values | Where-Object {
        ($_.Key -eq $SubstitutesSubKey -and $Set.Names -contains $_.Name) -or
        ($_.Key -eq $FontsSubKey -and (Get-LeafName ([string]$_.Data)) -ieq $Set.File) -or
        ($_.Key -eq $SystemLinkSubKey -and
            @(@($_.Data) | Where-Object { (Get-LeafName (([string]$_) -split ',')[0]) -ieq $Set.File }).Count)
    })
    if (-not $entries) { return }
    $result = Restore-JournalEntries $journal $entries
    Save-Journal $journal
    Write-Host "Put back $($result.Restored) value(s) for $Label as they were."
    Write-Skipped $result.Skipped
}

#endregion

#region Settings

function Save-Settings {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $json = ConvertTo-Json @{ TargetFace = $TargetFace; IncludeBatang = [bool]$IncludeBatang }
    [IO.File]::WriteAllText($SettingsFile, $json, (New-Object Text.UTF8Encoding $false))
}

#endregion

#region Actions

function Invoke-Apply {
    $targetFile = Get-MachineFontFile $TargetFace
    if (-not $targetFile -and $Quiet -and $TargetFace -ne $DefaultFace) {
        # The chosen font was uninstalled. At startup, keep Gulim away with the default font rather
        # than failing at every boot; the menu shows the change.
        Write-Log "Target font '$TargetFace' is no longer installed for all users; using $DefaultFace."
        $script:TargetFace = $DefaultFace
        $targetFile = Get-MachineFontFile $TargetFace
        if (Test-Path $SettingsFile) { Save-Settings }
    }
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

function Invoke-Install([string]$DoneMessage = 'Installed. The fix is applied again at every startup and sign-in.') {
    # This copy is about to run as SYSTEM at every startup.
    Assert-SafeSource

    # Narrowing the scope (Gulim + Batang -> Gulim only): put Batang back first, so it isn't left
    # replaced with nothing keeping it that way.
    $installed = Get-InstalledOptions
    if ($installed -and $installed.IncludeBatang -and -not $IncludeBatang) {
        Restore-FontSet $FontSets.Batang 'Batang/Gungsuh'
    }

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
    Save-Settings

    Write-Host ''
    Write-Host $DoneMessage -ForegroundColor Green
    if ($changed) { Write-Host $RestartHint -ForegroundColor Yellow }
}

# Whether there is anything for Uninstall to remove.
function Test-Installed {
    return (Test-Path $InstallDir) -or [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
}

function Invoke-Uninstall {
    if (-not (Test-Installed)) {
        Write-Host 'Not installed: nothing to remove.'
        return
    }

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
    $result = Restore-JournalEntries $journal @($journal.Values)
    if ($result.Restored) { Write-Host "Put back $($result.Restored) registry value(s) as they were before the first change." }

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed the startup task '$TaskName'."
    }
    # Right after the task, so a folder that can't be fully deleted never reads as still installed.
    if (Test-Path $SettingsFile) { Remove-Item $SettingsFile -Force }

    if ($result.Skipped) {
        # Keep the journal (now only these entries) and the folder, so a later Uninstall can finish.
        Save-Journal $journal
        Write-Skipped $result.Skipped
        Write-Host "They are kept in $JournalFile. Run Uninstall again once the font files are back." -ForegroundColor Yellow
        Write-Host "Uninstalled, except for the values above. $RestartHint" -ForegroundColor Yellow
        return
    }

    # Stay out of the folder being deleted when the installed copy itself is running.
    Set-Location $SystemDir
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
    Write-Host "Uninstalled: everything this tool changed is back as it was. $RestartHint" -ForegroundColor Green
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
        # Registry put back but this session still draws the target: removal finishes at restart.
        Removing   = $renderOk -and -not $registryOk
        Task       = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
}

# Pads text to a console width, counting Hangul, Hanja and other wide characters as two columns.
function Format-Cell([string]$Text, [int]$Width) {
    $columns = 0
    foreach ($char in $Text.ToCharArray()) { $columns += $(if ([int]$char -ge 0x1100) { 2 } else { 1 }) }
    return $Text + (' ' * [Math]::Max(1, $Width - $columns))
}

function Format-LastRun($Task) {
    $info = $Task | Get-ScheduledTaskInfo
    # A task that has never run reports 1999-11-30.
    if ($info.LastRunTime.Year -lt 2000) { return 'not run yet' }
    return "last run $($info.LastRunTime)"
}

function Show-Status {
    $targetNames = Get-FamilyNames $TargetFace
    $targetFile = Get-MachineFontFile $TargetFace
    if ($targetFile) {
        Write-Host "Target font : $TargetFace ($($targetNames -join ', ')) = $targetFile"
    } else {
        Write-Host "Target font : $TargetFace  -- NOT INSTALLED FOR ALL USERS" -ForegroundColor Red
    }

    $verdictSets = Get-FontSets
    $problems = 0

    foreach ($setName in $FontSets.Keys) {
        $set = $FontSets[$setName]
        $counts = $verdictSets -contains $set
        $present = Test-Path (Join-Path $FontsDir $set.File)
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

        Write-Host ('  ' + (Format-Cell 'Name' 13) + (Format-Cell 'Substitute' 21) + 'GDI renders as (this session)')
        foreach ($name in $set.Names) {
            $substitute = Get-RegValue $SubstitutesSubKey $name
            $actual = Resolve-GdiFamily $name
            $ok = $targetNames -contains $actual
            if ($counts -and -not $ok) { $problems++ }
            $color = if ($ok) { 'Green' } elseif ($counts) { 'Red' } else { 'Gray' }
            Write-Host ('  ' + (Format-Cell $name 13) + (Format-Cell $(if ($substitute) { $substitute } else { '-' }) 21) + $actual) -ForegroundColor $color
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
        $result = ($task | Get-ScheduledTaskInfo).LastTaskResult
        Write-Host "Automation  : installed, $(Format-LastRun $task), result $result"
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
    Write-Host "$problems problem(s) found. If you just installed or uninstalled: $RestartHint" -ForegroundColor Red
    return 1
}

# Fonts that can replace Gulim: the default first, then every other installed font that covers
# Hangul, sorted by name. Gulim, Batang and their relatives are left out. Usable means installed for
# all users and known to GDI by that name; per-user fonts are listed but the startup task (SYSTEM)
# can't see them.
function Get-FaceChoices {
    Add-Type -AssemblyName PresentationCore
    $blockedNames = @($FontSets.Values | ForEach-Object { $_.Names })
    $others = foreach ($family in [Windows.Media.Fonts]::SystemFontFamilies) {
        $face = $family.Source
        if ($face -eq $DefaultFace -or $face.StartsWith('@')) { continue }
        $names = @($family.FamilyNames.Values)
        if (@($names | Where-Object { $blockedNames -contains $_ }).Count) { continue }
        $glyphs = $null
        $typeface = @($family.GetTypefaces()) | Select-Object -First 1
        if (-not $typeface -or -not $typeface.TryGetGlyphTypeface([ref]$glyphs)) { continue }
        $map = $glyphs.CharacterToGlyphMap
        if (-not ($map.ContainsKey(0xAC00) -and $map.ContainsKey(0xD7A3))) { continue }   # 가 .. 힣
        # Problem is why it can't be used: only this user can see it (the task runs as SYSTEM), or
        # GDI knows the font by another name, so a substitute naming it would fall back elsewhere.
        $problem = if (-not (Get-MachineFontFile $face)) { 'UserOnly' }
                   elseif ($names -notcontains (Resolve-GdiFamily $face)) { 'GdiName' }
                   else { $null }
        [pscustomobject]@{ Face = $face; LocalName = ($names | Where-Object { $_ -ne $face } | Select-Object -First 1)
            Usable = -not $problem; Problem = $problem }
    }
    $default = [pscustomobject]@{ Face = $DefaultFace; LocalName = '맑은 고딕'; Usable = $true; Problem = $null }
    return @($default) + @($others | Sort-Object Face -Unique)
}

# Lists the fonts that can replace Gulim and returns the one picked, or $null for Back.
function Select-TargetFace {
    $choices = @(Get-FaceChoices)
    $usable = @($choices | Where-Object Usable)
    Write-Host '  Render Gulim as:'
    for ($i = 0; $i -lt $usable.Count; $i++) {
        $choice = $usable[$i]
        $notes = @()
        if ($choice.Face -eq $DefaultFace) { $notes += 'default' }
        if ($choice.Face -eq $TargetFace) { $notes += 'current' }
        Write-Host ('  [{0}] {1}{2}{3}' -f ($i + 1), (Format-Cell $choice.Face 22), (Format-Cell ($notes -join ', ') 18), $choice.LocalName)
    }
    $userOnly = @($choices | Where-Object Problem -eq 'UserOnly' | ForEach-Object Face)
    if ($userOnly) {
        Write-Host ''
        Write-Host '  Installed for this user only, so the startup task can''t use them:' -ForegroundColor DarkGray
        Write-Host "  $($userOnly -join ', ')" -ForegroundColor DarkGray
        Write-Host '  To use one, reinstall it: right-click the font file > Show more options > Install for all users.' -ForegroundColor DarkGray
    }
    $otherName = @($choices | Where-Object Problem -eq 'GdiName' | ForEach-Object Face)
    if ($otherName) {
        Write-Host ''
        Write-Host '  Older Windows programs know these by another name, so they can''t replace Gulim:' -ForegroundColor DarkGray
        Write-Host "  $($otherName -join ', ')" -ForegroundColor DarkGray
    }
    Write-Host '  [0] Back'
    Write-Host ''
    $index = 0
    if (-not [int]::TryParse("$(Read-Host '  Select')", [ref]$index) -or $index -lt 1 -or $index -gt $usable.Count) { return $null }
    return $usable[$index - 1].Face
}

# A window that draws the same line through every way Gulim can reach the screen, so the patch can
# be seen working without hunting for an app that still asks for Gulim. Each row names the font that
# actually drew it. Reference rows at the bottom show real Gulim/Dotum for comparison.
function Show-TestWindow {
    if (-not ('GulimToMalgun.Painter' -as [type])) {
        Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
namespace GulimToMalgun {
  public static class Painter {
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFontW(int h, int w, int esc, int orient, int weight, uint italic, uint underline,
        uint strike, uint charset, uint outPrec, uint clipPrec, uint quality, uint pitchFamily, string face);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] static extern bool TextOutW(IntPtr dc, int x, int y, string s, int n);
    [DllImport("gdi32.dll")] static extern int SetBkMode(IntPtr dc, int mode);
    [DllImport("gdi32.dll")] static extern uint SetTextColor(IntPtr dc, uint color);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    // Dark title bar (DWMWA_USE_IMMERSIVE_DARK_MODE), as Windows apps get in dark mode.
    public static void DarkTitleBar(IntPtr hwnd) { int on = 1; DwmSetWindowAttribute(hwnd, 20, ref on, 4); }

    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);
    // Dark scroll bars, the theme Explorer uses in dark mode.
    public static void DarkScrollBars(IntPtr hwnd) { SetWindowTheme(hwnd, "DarkMode_Explorer", null); }
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern int AddFontResourceExW(string file, uint flags, IntPtr reserved);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern bool RemoveFontResourceExW(string file, uint flags, IntPtr reserved);

    // Draws text with plain GDI (TextOut), which goes through FontSubstitutes and font linking
    // exactly as older apps do. color is 0x00BBGGRR.
    public static void Text(Graphics g, int x, int y, string face, int px, int weight, uint charset, uint color, string text) {
      IntPtr dc = g.GetHdc();
      try {
        SetBkMode(dc, 1);
        SetTextColor(dc, color);
        IntPtr font = CreateFontW(-px, 0, 0, 0, weight, 0, 0, 0, charset, 0, 0, 5, 0, face);
        IntPtr old = SelectObject(dc, font);
        TextOutW(dc, x, y, text, text.Length);
        SelectObject(dc, old);
        DeleteObject(font);
      } finally { g.ReleaseHdc(dc); }
    }
  }
}
'@
    }
    Add-Type -AssemblyName System.Windows.Forms, PresentationCore, PresentationFramework, WindowsBase

    $sample = '가나다 한글 굴림 테스트 漢字 かな ABC 123'
    $targetNames = @(Get-FamilyNames $TargetFace)
    $blockedNames = @($FontSets.Values | ForEach-Object { $_.Names })
    # Draw at the screen's real resolution, so Windows doesn't stretch (and blur) the window.
    [void][GulimToMalgun.Painter]::SetProcessDPIAware()
    $screen = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $scale = $screen.DpiX / 96
    $screen.Dispose()

    # Follow the Windows app theme (Settings > Personalization > Colors).
    $theme = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue
    $dark = $theme -and $theme.AppsUseLightTheme -eq 0
    function Rgb([int]$R, [int]$G, [int]$B) { [Drawing.Color]::FromArgb($R, $G, $B) }
    if ($dark) {
        $palette = @{ Back = (Rgb 32 32 32); Ink = (Rgb 232 232 232); Muted = (Rgb 160 160 160); Line = (Rgb 58 58 58)
            Section = (Rgb 44 44 46); Sample = 0xE8E8E8
            Ok = @((Rgb 28 64 38), (Rgb 140 222 150)); Bad = @((Rgb 84 30 30), (Rgb 255 150 150)); Other = @((Rgb 58 58 58), (Rgb 160 160 160)) }
    } else {
        $palette = @{ Back = (Rgb 255 255 255); Ink = (Rgb 32 32 32); Muted = (Rgb 110 110 110); Line = (Rgb 232 232 232)
            Section = (Rgb 245 245 247); Sample = 0x202020
            Ok = @((Rgb 222 241 226), (Rgb 27 94 32)); Bad = @((Rgb 253 226 226), (Rgb 183 28 28)); Other = @((Rgb 236 236 236), (Rgb 110 110 110)) }
    }
    $wpfInk = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb($palette.Ink.R, $palette.Ink.G, $palette.Ink.B))
    $wpfBack = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb($palette.Back.R, $palette.Back.G, $palette.Back.B))

    # State is 'ok' (target font), 'bad' (Gulim/Batang) or 'other'.
    $rows = New-Object System.Collections.Generic.List[object]
    function Add-Row($Section, $Request, $Result, $State, $Face, $Image = $null) {
        $rows.Add([pscustomobject]@{ Section = $Section; Request = $Request; Result = $Result; State = $State
            Face = $Face; Image = $Image })
    }
    function Get-Verdict([string]$Family) {
        if ($targetNames -contains $Family) { return @($Family, 'ok') }
        if ($blockedNames -contains $Family) { return @($Family, 'bad') }
        return @($Family, 'other')
    }

    # 1. By name: what a GDI app gets when it asks for each Gulim/Batang name.
    foreach ($set in Get-FontSets) {
        foreach ($name in $set.Names) {
            $verdict = Get-Verdict (Resolve-GdiFamily $name)
            Add-Row 'By name (GDI)' $name $verdict[0] $verdict[1] $name
        }
    }

    # 2. Font linking: a Latin font asked to draw Korean borrows the missing glyphs through SystemLink.
    # The verdict is the chain order in the registry, which GDI picks up at the next startup; the
    # sample shows what this session actually draws.
    $linkFile = Get-MachineFontFile $LinkFace
    $blockedFiles = @(Get-FontSets | ForEach-Object { $_.File })
    $key = Open-HklmKey $SystemLinkSubKey
    if ($key) {
        try {
            foreach ($face in 'Tahoma', 'Microsoft Sans Serif', 'Segoe UI', 'MS UI Gothic', 'Lucida Sans Unicode') {
                $chain = @($key.GetValue($face))
                $first = $chain | ForEach-Object { Get-LeafName (([string]$_) -split ',')[0] } |
                    Where-Object { $_ -ieq $linkFile -or $blockedFiles -contains $_ } | Select-Object -First 1
                if (-not $first) { Add-Row 'Font link (GDI, by registry order)' $face 'no Korean font in chain' 'other' $face; continue }
                if ($first -ieq $linkFile) { Add-Row 'Font link (GDI, by registry order)' $face "borrows $LinkFace" 'ok' $face }
                else { Add-Row 'Font link (GDI, by registry order)' $face "borrows $($first.ToUpper())" 'bad' $face }
            }
        } finally { $key.Close() }
    }

    # 3. Default face: a name that is not installed falls back to the Korean default face.
    $verdict = Get-Verdict (Resolve-GdiFamily 'NoSuchFont-g2m')
    Add-Row 'Default (GDI)' '(missing font)' $verdict[0] $verdict[1] 'NoSuchFont-g2m'

    # 4. DirectWrite side (WPF here): it ignores FontSubstitutes, so only an unregistered Gulim keeps
    # it away. Browsers and Office use the same font list, with their own fallback when a name is missing.
    foreach ($name in @(Get-FontSets | ForEach-Object { $_.Names[0], $_.Names[4] })) {
        $typeface = New-Object Windows.Media.Typeface $name
        $glyphs = $null
        if ($typeface.TryGetGlyphTypeface([ref]$glyphs)) {
            $result = "found $(Get-LeafName $glyphs.FontUri.LocalPath)"; $state = 'bad'
        } else {
            $result = 'not in the font list'; $state = 'ok'
        }
        $text = New-Object Windows.Media.FormattedText ($sample, [Globalization.CultureInfo]'ko-KR',
            'LeftToRight', $typeface, 16, $wpfInk)
        $visual = New-Object Windows.Media.DrawingVisual
        $context = $visual.RenderOpen()
        $context.DrawRectangle($wpfBack, $null, (New-Object Windows.Rect 0, 0, 520, 24))
        $context.DrawText($text, (New-Object Windows.Point 0, 2))
        $context.Close()
        $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int](520 * $scale)), ([int](24 * $scale)),
            (96 * $scale), (96 * $scale), ([Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($visual)
        $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = New-Object IO.MemoryStream
        $encoder.Save($stream)
        # A copy, so the stream can be closed now.
        $streamImage = [Drawing.Image]::FromStream($stream)
        $rowImage = New-Object Drawing.Bitmap $streamImage
        $streamImage.Dispose()
        $stream.Dispose()
        Add-Row 'DirectWrite (WPF)' $name $result $state $null $rowImage
    }

    # Draw everything into one image. The reference rows load the real font files privately
    # (only this process sees them) after every other row is drawn, then unload them.
    $references = @(
        @{ Label = "$TargetFace (target)"; Face = $TargetFace; File = $null },
        @{ Label = 'REAL Gulim (gulim.ttc)'; Face = '굴림'; File = 'gulim.ttc' },
        @{ Label = 'REAL Dotum (gulim.ttc)'; Face = '돋움'; File = 'gulim.ttc' }
    )
    if ($IncludeBatang) {
        $references += @{ Label = 'REAL Batang (batang.ttc)'; Face = '바탕'; File = 'batang.ttc' }
        $references += @{ Label = 'REAL Gungsuh (batang.ttc)'; Face = '궁서'; File = 'batang.ttc' }
    }
    # Only the sample text goes through GDI, because that is what is being tested. Everything around it
    # is drawn antialiased with GDI+ in Malgun Gothic, which the patch never touches.
    $problems = @($rows | Where-Object State -eq 'bad').Count
    $summary = if ($problems) { "$problems path(s) still show Gulim" } else { 'No path shows Gulim' }
    function S([double]$Value) { [int][Math]::Round($Value * $scale) }
    $width = 1080
    $rowHeight = 32
    $sections = @($rows | ForEach-Object Section | Select-Object -Unique).Count + 1
    $height = 134 + ($rows.Count + $references.Count) * $rowHeight + $sections * 40 + 12
    $image = New-Object Drawing.Bitmap (S $width), (S $height), ([Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [Drawing.Graphics]::FromImage($image)
    $graphics.Clear($palette.Back)
    $graphics.SmoothingMode = 'AntiAlias'
    $graphics.TextRenderingHint = 'AntiAliasGridFit'
    $ink = $palette.Ink
    $muted = $palette.Muted
    $line = New-Object Drawing.Pen $palette.Line, 1
    $badges = @{
        ok    = @{ Text = 'OK';    Back = $palette.Ok[0];    Fore = $palette.Ok[1] }
        bad   = @{ Text = 'GULIM'; Back = $palette.Bad[0];   Fore = $palette.Bad[1] }
        other = @{ Text = '?';     Back = $palette.Other[0]; Fore = $palette.Other[1] }
    }
    $fontCache = @{}
    function Write-Label([string]$Text, [double]$X, [double]$Y, [double]$Size = 13, [string]$Style = 'Regular', $Color = $ink) {
        $id = "$Size|$Style"
        if (-not $fontCache[$id]) { $fontCache[$id] = New-Object Drawing.Font 'Malgun Gothic', (S $Size), ([Drawing.FontStyle]$Style), ([Drawing.GraphicsUnit]::Pixel) }
        $brush = New-Object Drawing.SolidBrush $Color
        $graphics.DrawString($Text, $fontCache[$id], $brush, (S $X), (S $Y))
        $brush.Dispose()
    }
    function Write-Badge([string]$State, [double]$X, [double]$Y) {
        $badge = $badges[$State]
        $brush = New-Object Drawing.SolidBrush $badge.Back
        $graphics.FillRectangle($brush, (S $X), (S $Y), (S 54), (S 20))
        $brush.Dispose()
        $format = New-Object Drawing.StringFormat
        $format.Alignment = 'Center'; $format.LineAlignment = 'Center'
        if (-not $fontCache.badge) { $fontCache.badge = New-Object Drawing.Font 'Segoe UI', (S 11), ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel) }
        $brush = New-Object Drawing.SolidBrush $badge.Fore
        $graphics.DrawString($badge.Text, $fontCache.badge, $brush, (New-Object Drawing.RectangleF (S $X), (S $Y), (S 54), (S 20)), $format)
        $brush.Dispose()
    }
    function Write-Section([string]$Title, [double]$Y) {
        $brush = New-Object Drawing.SolidBrush $palette.Section
        $graphics.FillRectangle($brush, 0, (S $Y), (S $width), (S 30))
        $brush.Dispose()
        Write-Label $Title 20 ($Y + 5) 14 'Bold'
    }

    $y = 18
    Write-Label 'gulim-to-malgun test' 20 $y 22 'Bold'
    Write-Label "target: $TargetFace    $(Get-Date -Format 'yyyy-MM-dd HH:mm')" 270 ($y + 7) 13 'Regular' $muted
    $y += 40
    $badgeBack = if ($problems) { $badges.bad } else { $badges.ok }
    $brush = New-Object Drawing.SolidBrush $badgeBack.Back
    $graphics.FillRectangle($brush, (S 20), (S $y), (S ($width - 40)), (S 34))
    $brush.Dispose()
    Write-Label "$summary.  OK = the patch works on that path, GULIM = Gulim still reaches the screen. Changes show after you restart Windows." 32 ($y + 8) 13 'Regular' $badgeBack.Fore
    $y += 50
    # Column headers once, over the columns the rows actually use.
    Write-Label 'Result' 20 $y 12 'Regular' $muted
    Write-Label 'Requested font' 90 $y 12 'Regular' $muted
    Write-Label 'Actually drawn with' 300 $y 12 'Regular' $muted
    Write-Label 'Sample (as an app sees it)' 560 $y 12 'Regular' $muted
    $y += 26

    $section = $null
    foreach ($row in $rows) {
        if ($row.Section -ne $section) {
            $section = $row.Section
            Write-Section $section $y
            $y += 40
        }
        Write-Badge $row.State 20 ($y + 6)
        Write-Label $row.Request 90 ($y + 7)
        Write-Label $row.Result 300 ($y + 7) 13 'Regular' $(if ($row.State -eq 'bad') { $badges.bad.Fore } else { $ink })
        if ($row.Image) { $graphics.DrawImage($row.Image, (S 560), (S ($y + 3)), $row.Image.Width, $row.Image.Height) }
        else { [GulimToMalgun.Painter]::Text($graphics, (S 560), (S ($y + 5)), $row.Face, (S 16), 400, 1, $palette.Sample, $sample) }
        $graphics.DrawLine($line, (S 20), (S ($y + $rowHeight - 1)), (S ($width - 20)), (S ($y + $rowHeight - 1)))
        $y += $rowHeight
    }
    Write-Section 'Reference' $y
    $y += 40
    foreach ($reference in $references) {
        $file = if ($reference.File) { Join-Path $FontsDir $reference.File }
        if ($file -and -not (Test-Path $file)) {
            # Removed with the Windows feature: drawing the name would only show the substitute.
            Write-Label "$($reference.Label) - file removed" 90 ($y + 7) 13 'Regular' $muted
        } else {
            $loaded = $file -and [GulimToMalgun.Painter]::AddFontResourceExW($file, 0x10, [IntPtr]::Zero)
            try {
                Write-Label $reference.Label 90 ($y + 7)
                [GulimToMalgun.Painter]::Text($graphics, (S 560), (S ($y + 5)), $reference.Face, (S 16), 400, 1, $palette.Sample, $sample)
            } finally {
                # Unload even on error: while loaded, Gulim would win over the substitutes in this process.
                if ($loaded) { [void][GulimToMalgun.Painter]::RemoveFontResourceExW($file, 0x10, [IntPtr]::Zero) }
            }
        }
        $graphics.DrawLine($line, (S 20), (S ($y + $rowHeight - 1)), (S ($width - 20)), (S ($y + $rowHeight - 1)))
        $y += $rowHeight
    }
    $fontCache.Values | ForEach-Object { $_.Dispose() }
    $rows | Where-Object Image | ForEach-Object { $_.Image.Dispose() }
    $line.Dispose()
    $graphics.Dispose()
    if ($OutFile) {
        $image.Save($OutFile, [Drawing.Imaging.ImageFormat]::Png)
        $image.Dispose()
        Write-Host "Saved ${OutFile}: $summary."
        return
    }
    $form = New-Object Windows.Forms.Form
    $form.Text = "gulim-to-malgun test - $summary"
    $workArea = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.ClientSize = New-Object Drawing.Size ([Math]::Min($image.Width + (S 20), $workArea.Width)),
        ([Math]::Min($image.Height + (S 12), [int]($workArea.Height * 0.9)))
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $palette.Back
    $panel = New-Object Windows.Forms.Panel
    $panel.Dock = 'Fill'; $panel.AutoScroll = $true
    $picture = New-Object Windows.Forms.PictureBox
    $picture.Image = $image; $picture.SizeMode = 'AutoSize'
    $panel.Controls.Add($picture)
    $form.Controls.Add($panel)
    # No buttons: Esc or the title bar closes it, and Test -OutFile saves the image.
    $form.KeyPreview = $true
    $form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $form.Close() } })
    if ($dark) {
        $form.Add_HandleCreated({ [GulimToMalgun.Painter]::DarkTitleBar($form.Handle) })
        $panel.Add_HandleCreated({ [GulimToMalgun.Painter]::DarkScrollBars($panel.Handle) })
    }
    Write-Host "Test window: $summary."
    [void]$form.ShowDialog()
    $form.Dispose()
    $image.Dispose()
}

#endregion

#region Console font
# Optional: one font for cmd and PowerShell windows. The Korean code page (949) only lets the console
# use Korean fonts, which this tool turns into Malgun Gothic, a proportional font that spreads Latin
# text across fixed-width cells. With UTF-8 (65001) the console accepts any fixed-width font, and
# Hangul is drawn through font linking at two cells per character.

function Open-ConsoleKey([string]$SubKey, [switch]$Writable) {
    if ($Writable) { return [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($SubKey) }
    return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey)
}

# The console font this tool set, or $null when the settings are still the user's own.
function Get-ConsoleFont {
    if (-not (Test-Path $ConsoleJournal)) { return $null }
    $key = Open-ConsoleKey $ConsoleKeys[0]
    if (-not $key) { return $null }
    try { [pscustomobject]@{ Face = $key.GetValue('FaceName'); Size = ([int]$key.GetValue('FontSize', 0) -shr 16) } } finally { $key.Close() }
}

function Set-ConsoleFont([string]$Face, [int]$Size) {
    # Originals first and only once, so Restore puts back what was there before the first change.
    if (-not (Test-Path $ConsoleJournal)) {
        $originals = foreach ($subKey in $ConsoleKeys) {
            $key = Open-ConsoleKey $subKey
            foreach ($name in $ConsoleValues) {
                $existed = $key -and ($key.GetValueNames() -contains $name)
                [pscustomobject]@{ Key = $subKey; Name = $name; Existed = [bool]$existed
                    Kind = $(if ($existed) { [string]$key.GetValueKind($name) } else { $null })
                    Data = $(if ($existed) { $key.GetValue($name) } else { $null }) }
            }
            if ($key) { $key.Close() }
        }
        New-Item -ItemType Directory -Path (Split-Path $ConsoleJournal) -Force | Out-Null
        [IO.File]::WriteAllText($ConsoleJournal, (ConvertTo-Json -InputObject @($originals) -Depth 3), (New-Object Text.UTF8Encoding $false))
    }
    foreach ($subKey in $ConsoleKeys) {
        $key = Open-ConsoleKey $subKey -Writable
        try {
            $key.SetValue('FaceName', $Face, 'String')
            $key.SetValue('FontFamily', 54, 'DWord')            # TrueType, fixed pitch
            $key.SetValue('FontSize', ($Size -shl 16), 'DWord')  # height in the high word
            $key.SetValue('FontWeight', 400, 'DWord')
            $key.SetValue('CodePage', 65001, 'DWord')           # UTF-8
        } finally { $key.Close() }
    }
}

function Restore-ConsoleFont {
    foreach ($entry in (Get-Content $ConsoleJournal -Raw -Encoding UTF8 | ConvertFrom-Json)) {
        if ($ConsoleKeys -notcontains $entry.Key -or $ConsoleValues -notcontains $entry.Name) { continue }
        $key = Open-ConsoleKey $entry.Key -Writable
        try {
            if ($entry.Existed) { $key.SetValue($entry.Name, $entry.Data, [Microsoft.Win32.RegistryValueKind]$entry.Kind) }
            else { $key.DeleteValue($entry.Name, $false) }
        } finally { $key.Close() }
    }
    Remove-Item $ConsoleJournal -Force
}

function Select-ConsoleFont {
    $current = Get-ConsoleFont
    $faces = @($ConsoleFaces | Where-Object { @(Get-FamilyNames $_).Count })
    Write-Host '  Use one font for cmd and PowerShell windows (your account only):'
    for ($i = 0; $i -lt $faces.Count; $i++) {
        $note = if ($current -and $current.Face -eq $faces[$i]) { "current, $($current.Size)px" } else { '' }
        Write-Host ('  [{0}] {1}{2}' -f ($i + 1), (Format-Cell $faces[$i] 22), $note)
    }
    $restore = $faces.Count + 1
    if ($current) { Write-Host "  [$restore] Put back the console settings from before" }
    Write-Host '  [0] Back'
    Write-Host ''
    $index = 0
    if (-not [int]::TryParse("$(Read-Host '  Select')", [ref]$index) -or $index -lt 1 -or $index -gt $restore -or
        ($index -eq $restore -and -not $current)) {
        Write-Host 'Console font unchanged.'
        return
    }
    if ($index -eq $restore) {
        Restore-ConsoleFont
        Write-Host 'Console settings put back. Open a new cmd or PowerShell window to see it.' -ForegroundColor Green
        return
    }

    $face = $faces[$index - 1]
    $size = if ($current) { $current.Size } else { 16 }
    $answer = "$(Read-Host "  Size in pixels, 12-32 [$size]")".Trim()
    if ($answer) {
        $parsed = 0
        if (-not [int]::TryParse($answer, [ref]$parsed) -or $parsed -lt 12 -or $parsed -gt 32) {
            Write-Host 'Console font unchanged: the size must be a number from 12 to 32.' -ForegroundColor Yellow
            return
        }
        $size = $parsed
    }
    Write-Host ''
    Write-Host "  cmd and PowerShell windows will use $face at ${size}px, with UTF-8 text (code page 65001)."
    Write-Host '  UTF-8 is needed because the Korean code page only allows Korean fonts. Old programs and'
    Write-Host '  .bat files that print Korean in the legacy encoding may show it garbled; [7] can undo this.'
    if ((Read-Host '  Apply? (y/N)') -ne 'y') {
        Write-Host 'Console font unchanged.'
        return
    }
    Set-ConsoleFont $face $size
    Write-Host "Done. Open a new cmd or PowerShell window to see it. Windows Terminal has its own font setting." -ForegroundColor Green
}

#endregion

#region Menu

function Show-Menu {
    $requestedBatang = [bool]$IncludeBatang
    $requestedFace = $TargetFace
    # Each action starts on a clean screen, and the menu is drawn again below its output, so the
    # screen holds only the last action and the next number can be picked right away.
    # Enter alone redraws the menu on a clean screen.
    $titles = @{ '1' = 'Install - Gulim only'; '2' = 'Install - Gulim + Batang/Gungsuh'; '3' = 'Status'
        '4' = 'Uninstall'; '5' = 'Font'; '6' = 'Test'; '7' = 'Console font' }
    $clear = $true
    while ($true) {
        if ($clear) { Clear-Host } else { Write-Host '  ============================================================'; Write-Host '' }
        $clear = $false
        # Judge the patch by what is installed: Batang counts only if the task replaces it too.
        $installed = Get-InstalledOptions
        if ($installed) {
            $script:IncludeBatang = $installed.IncludeBatang
            $script:TargetFace = $installed.TargetFace
        } else {
            $script:IncludeBatang = $requestedBatang
            $script:TargetFace = $requestedFace
        }
        $scope = if ($IncludeBatang) { 'Gulim + Batang/Gungsuh' } else { 'Gulim' }
        $state = Get-PatchState
        $console = Get-ConsoleFont
        Write-Host "  gulim-to-malgun  |  $scope -> $TargetFace"
        Write-Host '  ------------------------------------------------------------'
        if ($state.RenderOk) {
            Write-Host "  Patch      : Applied - $scope renders as $TargetFace" -ForegroundColor Green
        } elseif ($state.RegistryOk) {
            Write-Host "  Patch      : Applied - $RestartHint" -ForegroundColor Yellow
        } elseif ($state.Removing) {
            Write-Host "  Patch      : Removed - $RestartHint" -ForegroundColor Yellow
        } else {
            Write-Host "  Patch      : Not applied - $scope renders as the original font" -ForegroundColor Red
        }
        if ($state.Task) {
            Write-Host "  Automation : Installed - fixes it again at every startup ($(Format-LastRun $state.Task))" -ForegroundColor Green
        } else {
            Write-Host '  Automation : Not installed - Windows updates may bring Gulim back' -ForegroundColor Yellow
        }
        $consoleText = if ($console) { "$($console.Face) $($console.Size)px" } else { 'Windows default' }
        Write-Host "  Console    : $consoleText"
        Write-Host ''
        $items = @(
            @('1', 'Install - Gulim only', 'Fix it now and keep it fixed at every startup'),
            @('2', 'Install - Gulim + Batang/Gungsuh', 'Same, and replace Batang/Gungsuh too'),
            @('3', 'Status', 'Show which font each Gulim name really uses'),
            @('4', 'Uninstall', 'Put everything back as it was'),
            @('5', "Font - $TargetFace", 'Choose the font that replaces Gulim'),
            @('6', 'Test', 'Open a window that shows the fix working'),
            @('7', "Console font - $consoleText", 'One font for cmd and PowerShell windows'),
            @('0', 'Exit', '(Enter alone clears the screen)'))
        $activeItem = if (-not $installed) { $null } elseif ($installed.IncludeBatang) { '2' } else { '1' }
        foreach ($item in $items) {
            Write-Host ('  [{0}] {1}{2}' -f $item[0], (Format-Cell $item[1] 36), $item[2]) -NoNewline
            if ($item[0] -eq $activeItem) { Write-Host '  (installed)' -ForegroundColor Green } else { Write-Host '' }
        }
        Write-Host ''
        $choice = "$(Read-Host '  Select')".Trim()
        if ($choice -eq '0') { return }
        if (-not $titles.ContainsKey($choice)) { $clear = $true; continue }

        Clear-Host
        Write-Host "  [$choice] $($titles[$choice])" -ForegroundColor Cyan
        Write-Host ''
        try {
            switch ($choice) {
                '1' {
                    if ($installed -and $installed.IncludeBatang -and
                        (Read-Host '  Switch to Gulim only? Batang/Gungsuh will be put back as they were. (y/N)') -ne 'y') {
                        Write-Host 'Nothing changed.'
                    } else {
                        $script:IncludeBatang = $false
                        Invoke-Install
                    }
                }
                '2' { $script:IncludeBatang = $true; Invoke-Install }
                '3' { [void](Show-Status) }
                '4' {
                    if (-not (Test-Installed)) {
                        Write-Host 'Not installed: nothing to remove.'
                    } elseif ((Read-Host '  Remove the fix and put everything back as it was? (y/N)') -eq 'y') {
                        Invoke-Uninstall
                    } else {
                        Write-Host 'Nothing changed.'
                    }
                }
                '5' {
                    $face = Select-TargetFace
                    Write-Host ''
                    if (-not $face -or $face -eq $TargetFace) {
                        Write-Host 'Font unchanged.'
                    } elseif (-not $installed) {
                        $requestedFace = $face
                        Write-Host "$face selected. Install with [1] or [2] to apply it."
                    } elseif ((Read-Host "  Switch Gulim to $face now? (y/N)") -eq 'y') {
                        # Only FontSubstitutes changes; the journal keeps the values from before the first change.
                        $script:TargetFace = $face
                        Invoke-Install "Switched: Gulim now renders as $face."
                    } else {
                        Write-Host 'Font unchanged.'
                    }
                }
                '6' {
                    Write-Host 'Test window open. Close it (Esc) to come back here.'
                    Show-TestWindow
                }
                '7' { Select-ConsoleFont }
            }
        } catch {
            Write-ErrorLog $_
            Write-ErrorHelp $_
        }
        Write-Host ''
    }
}

#endregion

if ($Action -in 'Status', 'Test') {
    # Check what is installed, unless the command line asks about something else.
    $installed = Get-InstalledOptions
    if ($installed -and -not $PSBoundParameters.ContainsKey('TargetFace')) { $TargetFace = $installed.TargetFace }
    if ($installed -and -not $PSBoundParameters.ContainsKey('IncludeBatang')) { $IncludeBatang = [switch]$installed.IncludeBatang }
    if ($Action -eq 'Test') { Show-TestWindow; exit 0 }
    exit (Show-Status)
}

if (-not (Test-Admin)) {
    if ($Quiet) { Write-Error "$Action -Quiet must run elevated."; exit 1 }
    # Don't hand administrator rights to a copy that other accounts can change. The check and the
    # copy run here, before elevation, on the file as it is now.
    # If other accounts can change it, run a protected copy instead, without asking: the user just
    # sees the administrator prompt, as when started from a safe folder.
    if (@(Get-UnsafeSourcePaths).Count) {
        $copy = New-ProtectedCopy
        if (@(Get-UnsafeSourcePaths $copy).Count) {
            Write-Host "ERROR: other accounts on this PC can change this folder, and the protected copy in $(Split-Path $copy -Parent) could not be locked down." -ForegroundColor Red
            exit 1
        }
        Write-Host "Running a protected copy from $(Split-Path $copy -Parent) (this folder can be changed by other accounts)."
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $copy) + $PSBoundParameters.Keys.ForEach({
            $value = $PSBoundParameters[$_]
            if ($_ -eq 'Action') { $value } elseif ($value -is [switch]) { if ($value) { "-$_" } } else { "-$_"; $value } })
        & $PowerShellExe @arguments
        exit $LASTEXITCODE
    }
    exit (Invoke-Elevated)
}

$exitCode = 0
try {
    switch ($Action) {
        'Menu'      { Show-Menu }
        'Install'   { Invoke-Install }
        'Uninstall' { Invoke-Uninstall }
        'Apply'     {
            if ((Invoke-Apply) -and -not $Quiet) { Write-Host $RestartHint }
        }
    }
} catch {
    $exitCode = 1
    Write-ErrorLog $_
    Write-Host "ERROR: $_" -ForegroundColor Red
} finally {
    # Keep an elevated window open so its output can be read; the menu waits on its own.
    if ($Elevated -and ($Action -ne 'Menu' -or $exitCode -ne 0)) { [void](Read-Host 'Press Enter to close') }
}
exit $exitCode
