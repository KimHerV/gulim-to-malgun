<#
.SYNOPSIS
    Makes Gulim (굴림) render as Malgun Gothic (맑은 고딕) and keeps it that way after Windows updates.
.DESCRIPTION
    Menu       (default) Numbered menu with the current patch state at the top.
    Install    Apply the fix now and re-apply it at every startup and sign-in.
    Uninstall  Remove the automation and put the font registry back the way it was.
    Status     Show what Gulim renders as right now, and why. Read-only, no admin needed.
    Apply      Apply once without installing anything. The scheduled task runs this.

    FontSubstitutes only applies to names that are not installed, and Windows updates
    re-register gulim.ttc. Apply removes that registration (the file stays in place) and
    points every Gulim/Dotum name at the target font. It does nothing when both are already
    in place, and backs up both registry keys before changing anything.
.PARAMETER TargetFace
    Font to render instead. Defaults to Malgun Gothic.
.PARAMETER IncludeBatang
    Also replace Batang, BatangChe, Gungsuh and GungsuhChe (바탕, 궁서).
.PARAMETER RemoveCapability
    Also uninstall the Korean Supplemental Fonts feature, which deletes gulim.ttc and batang.ttc.
    Only needed if Gulim still shows up after the registry fix. Uninstall reinstalls it
    (needs an internet connection).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\gulim-to-malgun.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\gulim-to-malgun.ps1 Install
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

$SubstitutesSubKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes'
$FontsSubKey       = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$CapabilityPattern = 'Language.Fonts.Kore*'
$TaskName          = 'gulim-to-malgun'

# The installed copy, backups and logs live where only administrators can write,
# because the scheduled task runs the installed copy as SYSTEM.
$InstallDir        = Join-Path $env:ProgramFiles 'gulim-to-malgun'
$InstalledScript   = Join-Path $InstallDir 'gulim-to-malgun.ps1'
$BackupDir         = Join-Path $InstallDir 'backup'
$LogFile           = Join-Path $InstallDir 'logs\apply.log'
$CapabilityMarker  = Join-Path $InstallDir 'capability-removed.txt'

#region Helpers

function Get-FontSets {
    if ($IncludeBatang) { return @($FontSets.Values) }
    return @($FontSets.Gulim)
}

function Open-HklmKey([string]$SubKey, [switch]$Writable) {
    $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
    return $hklm.OpenSubKey($SubKey, [bool]$Writable)
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

function Get-Substitute([string]$Name) {
    $key = Open-HklmKey $SubstitutesSubKey
    try { return $key.GetValue($Name) } finally { $key.Close() }
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

# Family name of the font GDI actually loads for a requested face, after FontSubstitutes.
# Read from the loaded font's name table, so it reports the real font rather than the request.
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

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Re-runs this script in an elevated window with the same arguments plus -Elevated, and waits for it.
function Invoke-Elevated {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", $Action, '-Elevated',
        '-TargetFace', "`"$TargetFace`"")
    if ($IncludeBatang) { $argList += '-IncludeBatang' }
    if ($RemoveCapability) { $argList += '-RemoveCapability' }
    Write-Host 'Administrator rights are needed; opening an elevated window...'
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait
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
    $process = Start-Process reg.exe -ArgumentList $quoted -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) { throw "reg.exe $($Arguments -join ' ') failed with exit code $($process.ExitCode)" }
}

#endregion

#region Actions

function Invoke-Apply {
    if (-not (Get-FamilyNames $TargetFace)) { throw "Target font '$TargetFace' is not installed." }

    $steps = @()
    foreach ($set in Get-FontSets) {
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
        if (-not $Quiet) { Write-Host "Already applied: Gulim renders as $TargetFace." }
        return $false
    }

    # Backups are named by time; Uninstall restores the oldest, i.e. the state before the first change.
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Invoke-Reg @('export', "HKLM\$SubstitutesSubKey", (Join-Path $BackupDir "$stamp-FontSubstitutes.reg"), '/y', '/reg:64')
    Invoke-Reg @('export', "HKLM\$FontsSubKey", (Join-Path $BackupDir "$stamp-Fonts.reg"), '/y', '/reg:64')
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
        Add-Content -Path $CapabilityMarker -Value $capability.Name -Encoding UTF8
        Write-Log "Removed capability $($capability.Name)"
    }
    return $true
}

function Invoke-Install {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    if ($PSCommandPath -ne $InstalledScript) { Copy-Item $PSCommandPath $InstalledScript -Force }

    $changed = Invoke-Apply

    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstalledScript`" Apply -Quiet -TargetFace `"$TargetFace`""
    if ($IncludeBatang) { $arguments += ' -IncludeBatang' }
    if ($RemoveCapability) { $arguments += ' -RemoveCapability' }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $triggers = @(New-ScheduledTaskTrigger -AtStartup; New-ScheduledTaskTrigger -AtLogOn)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal `
        -Settings $settings -Description 'Keeps Gulim rendering as Malgun Gothic after Windows updates.' -Force | Out-Null

    Write-Host ''
    Write-Host "Installed. The fix is re-applied automatically at every startup and sign-in." -ForegroundColor Green
    if ($changed) { Write-Host 'Sign out and back in (or reboot) so running apps pick up the change.' }
}

function Invoke-Uninstall {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'."
    }

    $oldest = Get-ChildItem $BackupDir -Filter '*-FontSubstitutes.reg' -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -First 1
    if ($oldest) {
        $stamp = $oldest.Name -replace '-FontSubstitutes\.reg$', ''
        # reg import only adds or overwrites, so drop the names this tool manages first;
        # the import then brings back whichever of them existed originally.
        $substitutes = Open-HklmKey $SubstitutesSubKey -Writable
        try {
            foreach ($set in $FontSets.Values) {
                foreach ($name in $set.Names) { $substitutes.DeleteValue($name, $false) }
            }
        } finally { $substitutes.Close() }
        foreach ($key in 'FontSubstitutes', 'Fonts') {
            Invoke-Reg @('import', (Join-Path $BackupDir "$stamp-$key.reg"), '/reg:64')
        }
        Write-Host "Restored the font registry from before the first change ($stamp)."
    } else {
        Write-Host 'No backups found; the font registry was left as it is.'
    }

    if (Test-Path $CapabilityMarker) {
        foreach ($name in Get-Content $CapabilityMarker -Encoding UTF8 | Where-Object { $_ }) {
            Write-Host "Reinstalling $name (needs an internet connection)..."
            Add-WindowsCapability -Online -Name $name | Out-Null
        }
    }

    # Stay out of the folder being deleted when the installed copy itself is running.
    Set-Location $env:SystemRoot
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
    Write-Host 'Uninstalled. Sign out and back in (or reboot) for the change to take effect.' -ForegroundColor Green
}

function Show-Status {
    $targetNames = Get-FamilyNames $TargetFace
    if ($targetNames) {
        Write-Host "Target font : $TargetFace ($($targetNames -join ', '))"
    } else {
        Write-Host "Target font : $TargetFace  -- NOT INSTALLED" -ForegroundColor Red
    }

    $fontsDir = Join-Path $env:WINDIR 'Fonts'
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

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        $info = $task | Get-ScheduledTaskInfo
        Write-Host "Automation  : installed, last run $($info.LastRunTime), result $($info.LastTaskResult)"
    } else {
        Write-Host 'Automation  : not installed'
    }

    Write-Host ''
    if ($problems -eq 0 -and $targetNames) {
        Write-Host "OK: every checked name renders as $TargetFace." -ForegroundColor Green
        return 0
    }
    Write-Host "$problems name(s) do not render as $TargetFace yet. If you just installed, sign out and back in first." -ForegroundColor Red
    return 1
}

# Whether the registry is fixed, and whether GDI in this session already renders the target font.
# The registry can be fixed while rendering is not, until the next sign-in.
function Get-PatchState {
    $targetNames = Get-FamilyNames $TargetFace
    $registryOk = $true
    $renderOk = [bool]$targetNames
    foreach ($set in Get-FontSets) {
        if (@(Get-RegisteredFontEntries $set.File)) { $registryOk = $false }
        foreach ($name in $set.Names) {
            if ((Get-Substitute $name) -ne $TargetFace) { $registryOk = $false }
            if ($targetNames -notcontains (Resolve-GdiFamily $name)) { $renderOk = $false }
        }
    }
    [pscustomobject]@{
        RegistryOk = $registryOk
        RenderOk   = $renderOk
        Task       = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
}

function Show-Menu {
    while ($true) {
        Clear-Host
        $state = Get-PatchState
        Write-Host "  gulim-to-malgun  |  굴림 -> $TargetFace"
        Write-Host '  ------------------------------------------------'
        if ($state.RenderOk) {
            Write-Host "  패치 상태 : 적용됨 - 굴림이 $TargetFace(으)로 표시됩니다" -ForegroundColor Green
        } elseif ($state.RegistryOk) {
            Write-Host '  패치 상태 : 적용됨 - 로그아웃 후 다시 로그인하면 반영됩니다' -ForegroundColor Yellow
        } else {
            Write-Host '  패치 상태 : 적용 안 됨 - 굴림이 그대로 표시됩니다' -ForegroundColor Red
        }
        if ($state.Task) {
            $info = $state.Task | Get-ScheduledTaskInfo
            Write-Host "  자동 유지 : 설치됨 (마지막 실행 $($info.LastRunTime))" -ForegroundColor Green
        } else {
            Write-Host '  자동 유지 : 설치 안 됨 - 업데이트 후 굴림이 다시 나올 수 있습니다' -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host '  [1] 설치   지금 적용 + 업데이트 후에도 자동으로 다시 적용'
        Write-Host '  [2] 상태   이름별로 실제 표시되는 글꼴 자세히 보기'
        Write-Host '  [3] 제거   자동 유지 해제 + 원래 상태로 복원'
        Write-Host '  [0] 종료'
        Write-Host ''
        $choice = Read-Host '  번호 선택'
        if ($choice -eq '0' -or $choice -eq '') { return }
        if ($choice -notin '1', '2', '3') { continue }

        Write-Host ''
        try {
            switch ($choice) {
                '1' { Invoke-Install }
                '2' { [void](Show-Status) }
                '3' {
                    if ((Read-Host '  자동 유지를 해제하고 원래 상태로 되돌릴까요? (y/N)') -eq 'y') { Invoke-Uninstall }
                }
            }
        } catch {
            if (Test-Path (Split-Path $LogFile -Parent)) { Add-Content -Path $LogFile -Value "ERROR $_" -Encoding UTF8 }
            Write-Host "ERROR: $_" -ForegroundColor Red
        }
        Write-Host ''
        [void](Read-Host '  Enter를 누르면 메뉴로 돌아갑니다')
    }
}

#endregion

if ($Action -eq 'Status') { exit (Show-Status) }

if (-not (Test-Admin)) {
    if ($Quiet) { throw "$Action -Quiet must run elevated." }
    Invoke-Elevated
    return
}

if ($Action -eq 'Menu') {
    Show-Menu
    return
}

try {
    switch ($Action) {
        'Install'   { Invoke-Install }
        'Uninstall' { Invoke-Uninstall }
        'Apply'     {
            if ((Invoke-Apply) -and -not $Quiet) { Write-Host 'Sign out and back in (or reboot) so running apps pick up the change.' }
        }
    }
} catch {
    if (Test-Path (Split-Path $LogFile -Parent)) { Add-Content -Path $LogFile -Value "ERROR $_" -Encoding UTF8 }
    Write-Host "ERROR: $_" -ForegroundColor Red
    if (-not $Elevated) { throw }
} finally {
    if ($Elevated) { [void](Read-Host 'Press Enter to close') }
}
