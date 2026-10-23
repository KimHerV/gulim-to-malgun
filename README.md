# gulim-to-malgun

Make Gulim (굴림) render as Malgun Gothic (맑은 고딕) on Windows 11, and keep it that way after Windows updates.
Install once; it re-applies itself automatically.

## Install

Double-click `gulim-to-malgun.cmd` and approve the administrator prompt. A menu opens with the
current patch state at the top:

```
  gulim-to-malgun  |  굴림 -> Malgun Gothic
  ------------------------------------------------
  패치 상태 : 적용 안 됨 - 원래 글꼴(굴림)로 표시됩니다
  자동 유지 : 설치 안 됨 - 업데이트 후 굴림이 다시 나올 수 있습니다

  [1] 설치 - 굴림만             지금 적용 + 업데이트 후에도 자동으로 다시 적용
  [2] 설치 - 굴림 + 바탕·궁서   위와 같고, 바탕·궁서도 함께 바꿈
  [3] 상태   이름별로 실제 표시되는 글꼴 자세히 보기
  [4] 제거   자동 유지 해제 + 원래 상태로 복원
  [0] 종료
```

Choose `1` (or `2` to also replace Batang and Gungsuh), then sign out and back in. That's it: the fix is applied now and again at every startup
and sign-in, so an update can only bring Gulim back until the next reboot. Open the menu again any
time to see whether the patch is in effect.

The same actions work without the menu:

```powershell
powershell -ExecutionPolicy Bypass -File .\gulim-to-malgun.ps1 Install
powershell -ExecutionPolicy Bypass -File .\gulim-to-malgun.ps1 Status      # no admin needed
powershell -ExecutionPolicy Bypass -File .\gulim-to-malgun.ps1 Uninstall
```

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

## What it does

- Removes that registration (the font file stays where it is) and points every Gulim/Dotum name at
  Malgun Gothic. Does nothing when both are already in place.
- Backs up both registry keys before any change; `Uninstall` restores the oldest backup, i.e. the
  state before the first change.
- Copies itself to `C:\Program Files\gulim-to-malgun` and registers the scheduled task
  `gulim-to-malgun`, which runs that copy as SYSTEM at startup and sign-in. The copy lives where only
  administrators can change it because it runs as SYSTEM. Backups and `logs\apply.log` are kept there too.

Options for `Install` from the command line (they are remembered by the scheduled task; menu item `2` is `-IncludeBatang`):

- `-TargetFace "NanumBarunGothic"` - render Gulim as another installed font instead.
- `-IncludeBatang` - also replace Batang, BatangChe, Gungsuh and GungsuhChe (바탕, 궁서).
- `-RemoveCapability` - also uninstall the *Korean Supplemental Fonts* Windows feature, which
  deletes `gulim.ttc` and `batang.ttc`. Heavier; only needed if Gulim still shows up after the
  registry fix. `Uninstall` reinstalls it (needs an internet connection).

## Limits

- Running apps keep the fonts they loaded at sign-in; sign out and back in after installing.
- When an update re-registers Gulim, the first session after that reboot may still show it if
  sign-in finishes before the startup task runs. The next sign-in is fixed.
- Web pages that ask for `굴림` fall back to the browser's default font once Gulim is
  unregistered; set that default to Malgun Gothic in the browser if it is something else.
