---
name: windows-testing
description: Use before running hands-on tests on the owner's live Windows PC from WSL (desktop apps, tray tools, hotkeys, clipboard, focus), so testing never disrupts what they are doing.
---

# Hands-on testing on the owner's Windows PC

- Ask for a hands-off window first. Announce START (with the expected duration) and END.
- Save the owner's clipboard before and restore it after. Stop on the first surprise and report it.
- Never tap Alt to win focus: a lone Alt puts the focused window into menu mode, a modal loop that can freeze input (lost right-click and Alt+Tab). Focus by clicking inside your own topmost window, then put the cursor back.
- `Start-Process -WindowStyle Hidden` also hides the child's first shown window; call `ShowWindow(h, SW_SHOW)` afterwards when it must be visible.
- Show windows for screenshots without stealing focus: `SW_SHOWNOACTIVATE` (4) plus `PrintWindow`; minimize with `SW_SHOWMINNOACTIVE` (7).
- Wait on status files or process state, not sleeps; play pre-rendered WAV files, not live text-to-speech.
- Run under a Windows-side watchdog: WSL `timeout` leaves the Windows process running. On kill, release keys, discard recordings, restore the clipboard.
- `IsHungAppWindow` on hidden "Default IME" windows is baseline noise; check visible windows only, and check the foreground window for menu mode after each step.
- Question the test harness before blaming the product.
