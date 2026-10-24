gulim-to-malgun Changelog
=========================
#### v1.0.1 (unreleased)
- Changed release downloads to one file with the version in its name: `gulim-to-malgun-X.Y.Z.zip`
- Added the SHA-256 of the download and a verify command to the release notes

#### v1.0.0 (2026-10-24)
- Added the Gulim (굴림) to Malgun Gothic (맑은 고딕) fix through every path Gulim reaches the screen
- Added unregistering `gulim.ttc` (the file stays) and pointing all Gulim/Dotum names at the replacement font in FontSubstitutes
- Added Malgun Gothic ahead of Gulim in every FontLink\SystemLink chain
- Added a startup task (SYSTEM, at startup and sign-in) that re-applies only what an update has put back
- Added full reversal: every original value is recorded before it changes, and Uninstall puts back exactly those
- Added keeping values that can't be restored yet for a later Uninstall run
- Added optional Batang/Gungsuh (바탕, 궁서) replacement, and narrowing back to Gulim only
- Added a replacement font choice from installed fonts that cover Hangul and are installed for all users
- Added a fallback to Malgun Gothic if the chosen replacement font is later uninstalled
- Added a test window that draws a line through each Gulim name, font-linking fonts, unknown names and DirectWrite
- Added font labels and real Gulim for comparison in the test window, which follows the Windows light/dark theme
- Added `Test -OutFile` to save the test window as an image
- Added a Status text report that needs no administrator rights
- Added an optional console font for cmd and PowerShell windows (Cascadia Mono or Consolas, with UTF-8), restorable
- Added a numbered menu with the current state at the top, started from `gulim-to-malgun.cmd`
- Added a protected copy that runs when started from a folder other accounts can change (the installed copy runs as SYSTEM)
