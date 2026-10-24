<h1 align="center">gulim-to-malgun</h1>

<p align="center">
  Make Gulim (굴림) render as Malgun Gothic (맑은 고딕) on Windows 11, and keep it that way after updates.
</p>

<p align="center">
  <img alt="Windows 11" src="https://img.shields.io/badge/Windows-11-0078D6">
  <img alt="PowerShell 5.1" src="https://img.shields.io/badge/PowerShell-5.1-5391FE">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-green"></a>
</p>

<p align="center">
  <a href="https://github.com/KimHerV/gulim-to-malgun/archive/refs/heads/main.zip"><img alt="Download" src="https://img.shields.io/badge/Download-ZIP-2ea44f?style=for-the-badge"></a>
</p>

## Features

- **Gets rid of Gulim everywhere,** not just through the usual font substitute: also the cases where
  Windows ignores it, such as Hanja and kana borrowed from Gulim.
- **Stays fixed** after Windows updates: a startup task re-applies it.
- **Fully reversible:** Uninstall puts back exactly what it changed.
- **Optional:** Batang and Gungsuh too, another replacement font, and one font for cmd and PowerShell.
- **A test window** shows which font each path really draws with.

## Install

1. [Download the ZIP](https://github.com/KimHerV/gulim-to-malgun/archive/refs/heads/main.zip) and
   extract it.
2. Double-click `gulim-to-malgun.cmd` and approve the administrator prompt.
3. Choose `1`, then **restart Windows**.

Requires Windows 11 with Korean fonts; nothing else to install. Other Windows versions haven't been
tested. If Windows warns that the file came from the
internet, right-click the ZIP before extracting, choose Properties, and tick **Unblock**.

## Usage

Run `gulim-to-malgun.cmd` again any time. The menu shows the current state at the top:

```
  [1] Install - Gulim only                Fix it now and keep it fixed at every startup
  [2] Install - Gulim + Batang/Gungsuh    Same, and replace Batang/Gungsuh too
  [3] Replacement font: Malgun Gothic     Choose the font that replaces Gulim

  [4] Test                                Open a window that shows the fix working
  [5] Status                              Text report of which font each Gulim name uses

  [6] Console font: Windows default       Optional: font for cmd and PowerShell windows

  [7] Uninstall                           Put everything back as it was
  [0] Exit                                (Enter alone redraws the menu)
```

| Item | Notes |
|---|---|
| `3` Replacement font | Any installed font that covers Hangul, installed for all users. |
| `4` Test, `5` Status | No administrator rights needed. |
| `6` Console font | Cascadia Mono or Consolas, and UTF-8, for your account. Old programs that print Korean in the legacy encoding may show it garbled; `6` undoes it. |
| `7` Uninstall | Restart Windows afterwards. |

<details>
<summary>Command line</summary>

```powershell
powershell -ExecutionPolicy Bypass -File .\gulim-to-malgun.ps1 Install [-IncludeBatang] [-TargetFace "NanumGothic"]
powershell -ExecutionPolicy Bypass -File .\gulim-to-malgun.ps1 Uninstall
powershell -ExecutionPolicy Bypass -File .\gulim-to-malgun.ps1 Status
powershell -ExecutionPolicy Bypass -File .\gulim-to-malgun.ps1 Test [-OutFile result.png]
```

`-RemoveCapability` also uninstalls the *Korean Supplemental Fonts* feature, which deletes
`gulim.ttc` and `batang.ttc` (and GulimChe, Batang, Gungsuh with them). Uninstall reinstalls it.

</details>

<details>
<summary>How it works</summary>

The usual fix, mapping Gulim to another font under `FontSubstitutes`, is not enough. Gulim reaches
the screen three ways:

1. **By name.** While `gulim.ttc` is registered, Korean names such as `굴림` get the real Gulim
   whatever the substitutes say, and Chrome, Edge and Office ignore substitutes altogether.
2. **By font linking.** `FontLink\SystemLink` makes Tahoma, Microsoft Sans Serif and others borrow
   Hanja and kana from `GULIM.TTC`.
3. **By default face.** Unknown font names fall back to Gulim. Apps such as AMD Software draw Korean
   this way.

Install unregisters `gulim.ttc` (the file stays), points every Gulim name at the replacement font,
and puts Malgun Gothic ahead of Gulim in every font link. It records each original value first, in
`C:\Program Files\gulim-to-malgun`, and registers a startup task that runs as SYSTEM.

Because that copy runs as SYSTEM, the script won't run as administrator from a folder other accounts
can change; it quietly runs a protected copy from `%LOCALAPPDATA%\gulim-to-malgun\source` instead.

</details>

## Notes

- **Restart after installing or uninstalling.** Windows reads font settings when the session starts.
- **Small text looks heavier than Gulim.** Gulim has hand-drawn bitmaps for small sizes; Malgun
  Gothic doesn't.
- **Fixed-width text may shift,** since GulimChe and DotumChe were fixed-width and Malgun Gothic isn't.
- **Web pages** that ask for Gulim get the browser's default font instead.

## 한국어

윈도우 11에서 굴림 글꼴을 맑은 고딕으로 바꾸는 도구입니다(다른 윈도우 버전은 테스트하지 않았습니다). 굴림체·돋움·돋움체·바탕·궁서 제거, 업데이트 후
굴림이 다시 나올 때, 한자나 일본어가 굴림으로 보일 때, 프로그램 글꼴이 굴림으로 깨져 보일 때 쓸 수
있습니다. 폰트 대체(FontSubstitutes)와 글꼴 연결(SystemLink)을 함께 고치고, 한 번 설치하면 부팅할
때마다 다시 적용합니다. 언제든 원래대로 되돌릴 수 있습니다.

## License

[MIT](LICENSE) © 2026 KimHerV
