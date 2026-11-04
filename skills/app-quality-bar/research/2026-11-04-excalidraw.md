# S6 Excalidraw (2026-11-04)

Source ID: S6.
App: Excalidraw, open-source local-first whiteboard (https://excalidraw.com).
Repo: github.com/excalidraw/excalidraw at `dd2f8fc32b92cbf56f4abee6a0cf3b14681b4b55` (commit date 2026-11-03).
License: MIT (`LICENSE`).

## Provenance

- Studied: 2026-11-04, 19:36-19:46 UTC.
- Model: claude-opus-5-5, running as a Claude Code subagent.
- Repo read: shallow clone (`git clone --depth 1`) in the session scratch directory, files read with grep and sed; no code was run.
- Live: https://excalidraw.com at 1440x900 (welcome screen, Ctrl+/ command palette, ? help) and 390x844, light, signed out.
- Tools: git 2.x, chrome-devtools-axi 0.1.44 (headless Chromium 156), no Lighthouse run on reference apps.
- Evidence: screenshots are kept in the owner's private research repo (paths below), not in this public repo.

## Observations

- Data location on the first screen: the welcome screen says "Your drawings are saved in your browser's storage. Browser storage can be cleared unexpectedly. Save your work to a file regularly to avoid losing it." beside Open (Ctrl+O) and Help (?) (screenshot `secret-handling-review/evidence/2026-11-04/reference/excalidraw-1440-welcome.png`, phone `secret-handling-review/evidence/2026-11-04/reference/excalidraw-390.png`).
- Every tool button carries its shortcut in `aria-keyshortcuts` and in a small key label on the button (accessibility snapshot: "Rectangle, R or 2").
- Command palette: `packages/excalidraw/components/CommandPalette/CommandPalette.tsx` with `defaultCommandPaletteItems.ts`; live it opens on Ctrl+/, groups App, Export, Editor, shows key chips per command and a footer with arrow, Enter and Esc hints (`secret-handling-review/evidence/2026-11-04/reference/excalidraw-1440-palette.png`).
- Help dialog on `?` with a "Keyboard shortcuts" section (`secret-handling-review/evidence/2026-11-04/reference/excalidraw-1440-help.png`).
- Local save: `excalidraw-app/data/LocalData.ts` debounces saves (`SAVE_TO_LOCAL_STORAGE_TIMEOUT`, L125-140) and `flushSave` (L156) runs on blur, `visibilitychange` and unload (`excalidraw-app/App.tsx` L650-692); `excalidraw-app/data/tabSync.ts` versions browser state so another tab reloads newer data.
- Quota failures are shown, not swallowed: `localStorageQuotaExceeded` "Browser storage quota exceeded. Changes will not be saved." (`packages/excalidraw/locales/en.json` L299, `excalidraw-app/App.tsx` L834, L1078).
- Export and import: "Save to disk" and "Load from file", where loading warns it "will replace your existing content" and offers a backup first (`en.json` L640-660).
- Size budget in CI: `packages/excalidraw/.size-limit.json` (main bundle 340 kB, locales 290 kB, vendor 900 kB) with `.github/workflows/size-limit.yml`.
- Sentry: `excalidraw-app/sentry.ts` sets environment per host, `ignoreErrors` for known noise and a `beforeSend` filter (L24-73).

## Adopted

- Say where data lives on the first screen and nudge to export (section 16).
- Debounced local autosave flushed on blur and hide; cross-tab freshness (section 20).
- Visible quota errors; import warns before replacing (section 16).
- Key chips and `aria-keyshortcuts`; a `?` help dialog; palette footer hints (section 12).
- A size budget enforced in CI (section 15); Sentry noise filtering (section 21).

## Not copied

- No code, hand-drawn assets, fonts or copy.
- Ctrl+/ as the palette key: our apps use Ctrl/Cmd+K, which most web apps use.
