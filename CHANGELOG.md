# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-24

First release.

### Added
- **Gulim (굴림) renders as Malgun Gothic (맑은 고딕)** through every path it reaches the screen:
  unregisters `gulim.ttc` (the file stays), points all Gulim/Dotum names at the replacement font in
  FontSubstitutes, and puts Malgun Gothic ahead of Gulim in every FontLink\SystemLink chain.
- **Stays fixed:** a startup task (SYSTEM, at startup and sign-in) re-applies only what an update
  has put back.
- **Fully reversible:** every original value is recorded before it changes; Uninstall puts back
  exactly those, and keeps any it can't restore yet for a later run.
- Optional **Batang/Gungsuh** (바탕, 궁서) replacement, and narrowing back to Gulim only.
- **Replacement font** choice from every installed font that covers Hangul and is installed for all
  users. Falls back to Malgun Gothic if the chosen font is later uninstalled.
- **Test window** that draws one line through each Gulim name, the font-linking fonts, unknown font names and DirectWrite, labels the font that drew it, and shows real Gulim for comparison. Follows
  the Windows light/dark theme. `Test -OutFile` saves it as an image.
- **Status** text report, without administrator rights.
- Optional **console font** for cmd and PowerShell windows (Cascadia Mono or Consolas, with UTF-8),
  restorable.
- Numbered **menu** with the current state at the top, started from `gulim-to-malgun.cmd`.
- Runs a protected copy when started from a folder other accounts can change, since the installed
  copy runs as SYSTEM.

[1.0.0]: ../../releases/tag/v1.0.0
