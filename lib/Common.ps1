# Shared settings and helpers, dot-sourced by the top-level scripts.
# Saved as UTF-8 with BOM so Windows PowerShell 5.1 reads the Korean names correctly.

$DefaultTargetFace = 'Malgun Gothic'

# One entry per font file: the file name and every family name it registers (English and Korean).
$FontSets = [ordered]@{
    Gulim  = @{ File = 'gulim.ttc';  Names = @('Gulim', 'GulimChe', 'Dotum', 'DotumChe', '굴림', '굴림체', '돋움', '돋움체') }
    Batang = @{ File = 'batang.ttc'; Names = @('Batang', 'BatangChe', 'Gungsuh', 'GungsuhChe', '바탕', '바탕체', '궁서', '궁서체') }
}

$SubstitutesSubKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes'
$FontsSubKey       = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$CapabilityPattern = 'Language.Fonts.Kore*'
$TaskName          = 'gulim-to-malgun'

# Backups, logs and the copy the scheduled task runs live where only administrators can write,
# because the task runs as SYSTEM.
$InstallDir = Join-Path $env:ProgramFiles 'gulim-to-malgun'
$BackupDir  = Join-Path $InstallDir 'backup'
$LogFile    = Join-Path $InstallDir 'logs\apply.log'

function Get-FontSets([switch]$IncludeBatang) {
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

# Re-runs a script in an elevated window with the same arguments plus -Elevated, and waits for it.
function Invoke-Elevated([string]$ScriptPath, [hashtable]$BoundParameters) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"", '-Elevated')
    foreach ($name in $BoundParameters.Keys) {
        $value = $BoundParameters[$name]
        if ($value -is [switch]) {
            if ($value.IsPresent) { $argList += "-$name" }
        } else {
            $argList += "-$name"
            $argList += "`"$value`""
        }
    }
    Write-Host 'Administrator rights are needed; opening an elevated window...'
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait
}

# Keeps an elevated window open so its output can be read.
function Wait-IfElevated([bool]$Elevated) {
    if ($Elevated) { [void](Read-Host 'Press Enter to close') }
}

function Write-Log([string]$Message) {
    $dir = Split-Path $LogFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $Message
}

# Runs reg.exe outside PowerShell's stream handling: it prints success messages to stderr,
# which Windows PowerShell 5.1 turns into terminating errors under ErrorActionPreference Stop.
function Invoke-Reg([string[]]$Arguments) {
    $quoted = $Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }
    $process = Start-Process reg.exe -ArgumentList $quoted -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) { throw "reg.exe $($Arguments -join ' ') failed with exit code $($process.ExitCode)" }
}

# Exports both font keys to backup\<timestamp>-<key>.reg. Returns the timestamp.
function Backup-FontKeys {
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($pair in @(@('FontSubstitutes', $SubstitutesSubKey), @('Fonts', $FontsSubKey))) {
        $file = Join-Path $BackupDir "$stamp-$($pair[0]).reg"
        Invoke-Reg @('export', "HKLM\$($pair[1])", $file, '/y', '/reg:64')
    }
    return $stamp
}
