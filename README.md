# gulim-to-malgun

Make Gulim (굴림) render as Malgun Gothic (맑은 고딕) on Windows 11, and keep it that way after Windows updates.
Install once; it re-applies itself automatically.

## Install

The script runs as administrator and installs a copy that runs as SYSTEM, so it won't run as
administrator from a folder that anyone but you, administrators and SYSTEM can change (sandbox and
service accounts often have write access to drives and user folders). In that case it quietly
copies itself to `%LOCALAPPDATA%\gulim-to-malgun\source`, a folder only those accounts can change,
and runs that copy instead, so starting it works the same from anywhere.

Double-click `gulim-to-malgun.cmd` and approve the administrator prompt. A menu opens with the
current patch state at the top:

```
  gulim-to-malgun  |  Gulim -> Malgun Gothic
  ------------------------------------------------------------
  Patch      : Not applied - Gulim renders as the original font
  Automation : Not installed - Windows updates may bring Gulim back
  Console    : Windows default

  [1] Install - Gulim only                Fix it now and keep it fixed at every startup
  [2] Install - Gulim + Batang/Gungsuh    Same, and replace Batang/Gungsuh too
  [3] Status                              Show which font each Gulim name really uses
  [4] Uninstall                           Put everything back as it was
  [5] Font - Malgun Gothic                Choose the font that replaces Gulim
  [6] Test                                Open a window that shows the fix working
  [7] Console font - Windows default      One font for cmd and PowerShell windows
  [0] Exit                                (Enter alone clears the screen)
```

Choose `1` (or `2` to also replace Batang and Gungsuh), then **restart Windows**. That's it: the fix
is applied now and again at every startup and sign-in. The installed choice is marked `(installed)`.
Each action starts on a clean screen and shows its output with the menu below it, so you can pick the
next number right away; only `0` exits. Choosing `1` while Gulim + Batang is installed asks first,
then puts Batang/Gungsuh back as they were.

**Test (`6`).** To see the patch working without hunting for an app that still uses Gulim. It draws
the same line through every way Gulim can reach the screen (each name, font linking, the default
face, and DirectWrite), names the font that actually drew each row with an OK or GULIM badge, and
shows real Gulim, Dotum (and Batang, Gungsuh) underneath for comparison. It follows the Windows
light/dark app theme; `Esc` closes it. From the command line: `gulim-to-malgun.ps1 Test` (no admin
needed), or `Test -OutFile result.png` to save the image as a before/after record.

**Font (`5`).** Lists Malgun Gothic (the default) and every other installed font that covers Hangul.
Only fonts installed for all users can be picked, because the startup task runs as SYSTEM and can't
see per-user fonts; those are listed separately with how to fix it. If the fix is installed, it asks
and then switches right away with the same scope (restart afterwards); otherwise the choice is used
by the next `1` or `2`. If the chosen font is later uninstalled, the startup task falls back to
Malgun Gothic.

**Console font (`7`), optional.** Sets cmd and PowerShell windows to one fixed-width font (Cascadia
Mono or Consolas) and size, for your account only. The console only accepts Korean fonts under the
Korean code page, and those are exactly the fonts this tool turns into Malgun Gothic, a proportional
font that spaces Latin letters oddly in the console's fixed cells. So this option also switches the
console to UTF-8 (code page 65001); Hangul then comes from Malgun Gothic at two cells per character.
Old programs and `.bat` files that print Korean in the legacy encoding may show it garbled; `7` puts
the original settings back. Windows Terminal has its own font setting and is not affected, and a
Start-menu shortcut can carry its own console font, which wins over this setting. "Your account" is
the account that approves the administrator prompt; if that is a different administrator account,
the setting lands there.

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
   and from there through FontSubstitutes. Apps such as AMD Software (Qt) draw Korean this way.

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
  `Uninstall` puts back exactly those values and nothing else. If a value can't be put back yet (for
  example a font file is missing), it stays in the journal and the folder is kept, so a later
  `Uninstall` can finish. Whole-key `.reg` exports from before the first change are kept in
  `backup\` for manual recovery, and changes and errors are logged in `logs\apply.log`.

Options for `Install` from the command line (menu item `2` is `-IncludeBatang`):

- `-TargetFace "NanumBarunGothic"` - use another font installed for all users instead (menu item `5`).
- `-IncludeBatang` - also replace Batang, BatangChe, Gungsuh and GungsuhChe (바탕, 궁서). Installing
  without it over a Gulim + Batang install puts Batang/Gungsuh back first.
- `-RemoveCapability` - also uninstall the *Korean Supplemental Fonts* Windows feature, which
  deletes `gulim.ttc` and `batang.ttc`. The most thorough option, but it removes the fixed-width
  GulimChe/BatangChe and the serif Batang/Gungsuh for good, and updates may reinstall the feature.
  Done only during an interactive install, never by the scheduled task. `Uninstall` reinstalls it
  first (needs an internet connection).

## Limits

- GDI reads fonts, substitutes and font links when the session starts. Restart Windows after
  installing or uninstalling.
- After an update re-registers Gulim, the task fixes the registry at the next startup, but the
  session that started alongside it may still show Gulim. The restart after that is fixed.
- GulimChe and DotumChe are fixed-width; Malgun Gothic is not, so text aligned in columns with them
  may shift. In cmd and PowerShell windows this is what menu item `7` fixes.
- Gulim, Dotum and Batang carry hand-drawn bitmaps for small sizes (about 11-25 pixels), which is
  what makes them look thin and crisp. Malgun Gothic has none, so at the same size it looks heavier.
- Web pages that ask for `굴림` fall back to the browser's default font once Gulim is unregistered;
  set that default to Malgun Gothic in the browser if it is something else. The same goes for a
  target other than Malgun Gothic: Chrome, Edge, Office and other DirectWrite apps don't read
  FontSubstitutes, so another target shows up only in GDI apps (older programs and dialogs).
