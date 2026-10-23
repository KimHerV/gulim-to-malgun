# gulim-to-malgun

Make Gulim (굴림) render as Malgun Gothic (맑은 고딕) on Windows 11, and keep it that way after Windows updates.
Install once; it re-applies itself automatically.

## Install

Double-click `gulim-to-malgun.cmd` and approve the administrator prompt. A menu opens with the
current patch state at the top:

```
  gulim-to-malgun  |  Gulim -> Malgun Gothic
  ------------------------------------------------
  Patch      : Not applied - Gulim renders as the original font
  Automation : Not installed - Gulim may come back after Windows updates

  [1] Install - Gulim only             Apply now and re-apply after every update
  [2] Install - Gulim + Batang/Gungsuh Same, and replace Batang/Gungsuh too
  [3] Status                           Show what each name and fallback actually uses
  [4] Uninstall                        Remove automation and restore the original state
  [5] Font - Malgun Gothic             Choose the font Gulim renders as
  [0] Exit
```

Choose `1` (or `2` to also replace Batang and Gungsuh), then **reboot**. That's it: the fix is
applied now and again at every startup and sign-in. Open the menu again any time to see whether the
patch is in effect.

To render Gulim as another font, choose `5`. It lists Malgun Gothic and NanumBarunGothic (나눔바른고딕)
with whether each is installed for all users; only those can be picked, because the startup task runs
as SYSTEM and can't see per-user fonts. If the fix is installed, the switch happens right away with
the same scope (reboot afterwards); otherwise the choice is used by the next `1` or `2`.

The same actions work without the menu:

```powershell
powershell -ExecutionPolicy Bypass -File .\gulim-to-malgun.ps1 Install
powershell -ExecutionPolicy Bypass -File .\gulim-to-malgun.ps1 Status      # no admin needed
powershell -ExecutionPolicy Bypass -File .\gulim-to-malgun.ps1 Uninstall
```

## How Gulim reaches the screen

Mapping Gulim to another font under `HKLM\...\CurrentVersion\FontSubstitutes` is the usual fix,
and it is not enough on its own. Gulim gets in three ways:

1. **By name.** While `gulim.ttc` is registered under `...\CurrentVersion\Fonts`
   (`Gulim & GulimChe & Dotum & DotumChe (TrueType) = gulim.ttc`), a request for `굴림` gets the real
   Gulim: GDI lets the installed font win over the substitute for the Korean names, and DirectWrite
   apps (Chrome, Edge, Office) ignore FontSubstitutes entirely. Only removing the registration
   stops this.
2. **By font linking.** `...\FontLink\SystemLink` makes Tahoma, Microsoft Sans Serif, Lucida Sans
   Unicode and the MS Gothic family borrow missing glyphs from `GULIM.TTC` by file name, so Hanja and
   kana inside Korean text come out in Gulim even when the text font is something else.
3. **By default face.** Names that are not installed fall through to the Korean default face, Gulim,
   and from there through FontSubstitutes.

## What it does

- Removes the `gulim.ttc` registration (the font file stays where it is).
- Points all eight Gulim/Dotum names (English and Korean) at Malgun Gothic (or the font chosen with
  `5`) in FontSubstitutes.
- Inserts Malgun Gothic ahead of Gulim in every SystemLink chain that would reach Gulim first, in the
  same scaled + unscaled pair Windows uses for Segoe UI. Existing entries are kept. This is always
  Malgun Gothic, whichever font Gulim renders as: it ships with Windows, covers more Hanja (7,476
  against NanumBarunGothic's 4,621), and switching fonts then leaves SystemLink alone.
- Copies itself to `C:\Program Files\gulim-to-malgun` and registers the scheduled task
  `gulim-to-malgun`, which runs that copy as SYSTEM at startup and sign-in and changes only what an
  update has put back. The copy lives where only administrators can change it because it runs as
  SYSTEM.
- Records the original of every value it changes in `original-values.json` before changing it.
  `Uninstall` puts back exactly those values and nothing else. Whole-key `.reg` exports from before the
  first change are kept in `backup\` for manual recovery, and changes are logged in `logs\apply.log`.

Options for `Install` from the command line (menu item `2` is `-IncludeBatang`):

- `-TargetFace "NanumBarunGothic"` - use another font installed for all users instead (menu item `5`).
- `-IncludeBatang` - also replace Batang, BatangChe, Gungsuh and GungsuhChe (바탕, 궁서).
- `-RemoveCapability` - also uninstall the *Korean Supplemental Fonts* Windows feature, which
  deletes `gulim.ttc` and `batang.ttc`. The most thorough option, but it removes the fixed-width
  GulimChe/BatangChe and the serif Batang/Gungsuh for good, and updates may reinstall the feature.
  Done only during an interactive install, never by the scheduled task. `Uninstall` reinstalls it
  first (needs an internet connection).

## Limits

- GDI reads fonts, substitutes and font links when the session starts. Reboot after installing or
  uninstalling.
- After an update re-registers Gulim, the task fixes the registry at the next startup, but the
  session that started alongside it may still show Gulim. The reboot after that is fixed.
- GulimChe and DotumChe are fixed-width; Malgun Gothic is not, so text aligned in columns with them
  may shift.
- Web pages that ask for `굴림` fall back to the browser's default font once Gulim is unregistered;
  set that default to Malgun Gothic in the browser if it is something else. The same goes for a
  target other than Malgun Gothic: Chrome, Edge, Office and other DirectWrite apps don't read
  FontSubstitutes, so NanumBarunGothic shows up only in GDI apps (older programs and dialogs).
