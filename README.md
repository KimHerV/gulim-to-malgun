# gulim-to-malgun

Make Gulim (굴림) render as Malgun Gothic (맑은 고딕) on Windows 11, and keep it that way after Windows updates.

## Why the old registry trick stops working

The usual fix is to map Gulim to another font under
`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\FontSubstitutes`.
GDI only honours a substitute for a name that is **not installed**, though, and cumulative
updates re-register `gulim.ttc` under `...\CurrentVersion\Fonts`:

```
Gulim & GulimChe & Dotum & DotumChe (TrueType) = gulim.ttc
```

Once that value is back, `굴림`, `굴림체`, `돋움` and `돋움체` resolve to the real Gulim again and the
substitutes are silently ignored, even though they are still in the registry.

This project removes that registration (the font file stays where it is), points every
Gulim/Dotum name at Malgun Gothic, and can install a scheduled task that does the same at every
startup and sign-in, so an update can only bring Gulim back until the next reboot.

## Usage

Run from this folder in PowerShell. Scripts that need administrator rights open an elevated
window on their own.

```powershell
# What renders right now, and why (read-only)
powershell -ExecutionPolicy Bypass -File .\Check.ps1

# Apply once, then sign out and back in
powershell -ExecutionPolicy Bypass -File .\Apply.ps1

# Re-apply automatically after every update
powershell -ExecutionPolicy Bypass -File .\Install-Task.ps1
```

| Script | What it does |
|---|---|
| `Check.ps1` | Lists registration, substitutes and the font GDI actually loads for every name; exit code 1 if Gulim still renders |
| `Apply.ps1` | Backs up both keys, unregisters `gulim.ttc`, sets the substitutes. Does nothing if already applied |
| `Install-Task.ps1` | Copies `Apply.ps1` to `C:\Program Files\gulim-to-malgun` and runs it as SYSTEM at startup and sign-in |
| `Uninstall-Task.ps1` | Removes the task and the installed copy (keeps backups and logs) |
| `Restore.ps1` | Restores both keys from the oldest backup (the state before this tool first changed anything) |

Options shared by `Apply.ps1` and `Install-Task.ps1`:

- `-TargetFace "NanumBarunGothic"` - render Gulim as another installed font instead.
- `-IncludeBatang` - also replace Batang, BatangChe, Gungsuh and GungsuhChe (바탕, 궁서).
- `-RemoveCapability` - also uninstall the *Korean Supplemental Fonts* Windows feature, which
  deletes `gulim.ttc` and `batang.ttc`. Heavier; only needed if Gulim still shows up after the
  registry fix. `Restore.ps1 -AddCapability` reinstalls it (needs an internet connection).

Backups (`*.reg`) and `logs\apply.log` are kept in `C:\Program Files\gulim-to-malgun`.

## Limits

- Running apps keep the fonts they loaded at sign-in; sign out and back in after applying.
- When an update re-registers Gulim, the first session after that reboot may still show it if
  sign-in finishes before the startup task runs. The next sign-in is fixed.
- Web pages that ask for `굴림` fall back to the browser's default font once Gulim is
  unregistered; set that default to Malgun Gothic in the browser if it is something else.
