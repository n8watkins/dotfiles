---
name: app-quality-bar
description: Use when building, redesigning or reviewing the UI/UX of one of the owner's web apps (FitFlow 7, Feelium, Solara, Pivot, OpenPing or a new one). The checkable quality bar distilled from Solara and studied open-source apps, with sources, how to verify it, and the known gaps per app.
---

# App quality bar

Version 1.1, 2026-11-04, authored by claude-opus-5-5 running as a Claude Code subagent (see Version history below).
Every standard cites its sources in brackets: `S1`-`S9` are listed in `research/SOURCES.md` with a research record each, and `owner` marks an owner decision.
How studies are done and how a finding becomes a standard: `METHODOLOGY.md`.

The owner's apps should feel like Solara: you always know where you are, where things live, and that your data is kept.
Solara (github.com/n8watkins/solara, live at https://solara-uv.web.app/app/) is the reference; paths below are on its `main`.
Every item is a check you can pass or fail, not a taste note.
For a taste-driven or sweeping change, show a desktop preview first (then mobile) with screenshots and get approval, as the rules say. [owner]

## 1. App shell and navigation

- One shell component owns the frame: sticky header, optional view tabs, one centered main column (`components/AppShell.tsx`). [S1]
- Design desktop first, then phone: the column is about 900 px and widens to about 1240 px at 1024 px and up, with real multi-column layouts there, never one long phone column on a wide screen (`.dash-columns` in `app/globals.css`). [owner, S1]
- At most 3-5 top-level destinations; everything else is a section, a dialog or Settings. [S1]
  On phones the same destinations sit in a bottom tab bar or tabs under the header; a "More" drawer hiding half the app fails.
- The header, left to right: wordmark (goes home), the current context (Solara's place picker), then compact status and the account control on the right (`components/Header.tsx`, `Header.module.css`). [S1]
- Signed in, the right edge is an avatar button (photo or initial) that opens a menu: name and email, Settings, Account, Sign out in red (`components/AccountMenu.tsx`). [S1]
  It follows the WAI-ARIA menu button pattern: arrow keys, Home/End, Escape returns focus, outside click closes (`lib/roving-focus.ts`, `lib/use-outside-click.ts`).
  An avatar that is just a link to a settings page fails.
- Signed out, the same spot shows a Settings gear and a "Sign in" button, so theme and preferences are one tap away for guests too. [S1]
- Settings opens from anywhere through one opener (`lib/open-settings.ts`, `components/SettingsHost.tsx`), not by navigating away from the task. [S1]
- The page has exactly one `h1`; when the header and tab already say where you are, it can be visually hidden (`sr-only` in AppShell). [S1]
- Header content never truncates the most important thing: at 320-390 px drop secondary chips first (Solara hides the UV chip so the city fits). [S1]

## 2. Information architecture and density

- The first screen answers the app's main question without scrolling at 1440x900 and gets close at 390x844 (Solara: "Today at a glance" summary, then the chart beside the activity plan). [S1]
- Order a page by frequency of use: today's primary action and status first, setup and rare actions last or in Settings. [S1]
- One-time things (onboarding, tips, install prompts) never sit above the main content for returning users; Solara runs onboarding as its own 3-step flow, then shows one static, dismissible tip per visit (`lib/tips.ts`). [S1]
- Say a thing once: one disclaimer line, one Add button when a list is empty, no badge plus heading plus note repeating "done for today". [S1]
- Long lists collapse or paginate; a reference list (all exercises, all workouts) is its own view or a dialog, not appended under the dashboard. [S1]
- Plain words over jargon on cards; numbers carry their unit and a label. [S1]
- Use an SVG icon set (lucide-react) for UI chrome; emoji only for user content such as activity identity. [S1]

## 3. States: empty, loading, error, offline, saving

- Empty: one friendly line of what goes here, one primary action (`components/dashboard/ActivityEmptyState.tsx`). [S1]
- Loading: a skeleton shaped like the real layout so nothing jumps, with `role="status"` and hidden text (`components/Skeleton.tsx`); never a blank page or a lone spinner for the main view. [S1]
- A returning user sees their last data at once from a local copy while the network confirms (`lib/cached-account.ts`). [S1]
- Errors say what happened, that nothing was lost, and offer Retry (`AccountLoadError` in `components/AccountStatus.tsx`, `components/ErrorBoundary.tsx`). [S1]
- Offline and stale data are named with an "updated at" time (`components/ForecastNotice.tsx`, `messages/app.ts`), and edits are disabled with a reason rather than failing silently. [S1]
- Persistence is always visible:
  - say where data lives ("saved in this browser; sign in to keep it on every device") wherever a guest creates data, not only in Settings; [S1]
  - saving shows "Saving..." on the button, then a confirmation; a failed save says "Could not save, try again" and keeps the user's input; [S1]
  - partial failure is explicit ("Saved on this device, but cloud sync failed", `syncFailed` in `messages/dashboard.ts`); [S1]
  - signed-in apps with sync show a sync state (synced, syncing, error) in the header or avatar, visible without opening Settings. [S1]
- App-wide notices use one banner component with tones (notice, info, error), `role="status"` or `role="alert"`, and an action (`components/AppNotice.tsx`). [S1]

## 4. Forms and settings

- Settings is one dialog with a left section list on desktop and a tab bar on phones, a fixed height so switching sections does not resize it, and full screen on phones (`components/PreferencesModal.tsx`, `components/settings/SettingsTabs.tsx`, `Dialog` variant `sheet`). [S1]
- Each section has a title, a one-line description and grouped cards (`components/settings/SettingsCard.tsx`); a 2000 px single scrolling settings page fails. [S1]
- Pick one save model per surface and make it obvious:
  - a draft with Cancel and "Save settings" in a sticky footer, plus "Discard unsaved changes?" on close (`lib/settings.ts` `isSettingsDraftDirty`); [S1]
  - or save-as-you-go, where every change shows a per-control "Saved" or an error that reverts visibly. [S1]
- Inputs: labels always visible, errors next to the field in words, autocomplete with keyboard and screen reader support (`components/PlaceSearch.tsx`). [S1]
- Destructive actions sit in their own danger group and confirm in a dialog that names what is lost. [S1, S7]

## 5. Sign-in

- Sign-in is a modal over the current page, never a separate login page (owner preference); deep links like `?signin` open the modal. [owner]
- It offers the provider buttons and a clear "Continue without an account" when the app supports guests; reuse the copy and card layout of `components/SignInScreen.tsx`, which in Solara is still a full screen, inside the modal. [owner, S1]
- After sign-in the user lands back where they were, and a guest's data is merged or the user is told exactly what was not carried over (`components/GuestPlanNotice.tsx`). [S1]

## 6. Dialogs and overlays

- One modal primitive on the native `<dialog>` with `showModal()`: focus trap, Escape and Android back route through `onClose`, body scroll lock, focus returns to the opener (`components/Dialog.tsx`, `lib/useBodyScrollLock.ts`). [S1]
- Variants: `card`, `narrow`, `sheet`; non-modal details use a bottom sheet (`components/BottomSheet.tsx`). [S1]
- Close button top right, primary action bottom right, safe-area padding on phones (`env(safe-area-inset-*)`). [S1]

## 7. Visual tokens, type and motion

- Colors are semantic tokens defined once with light and dark values: surface, card, metric, line, ink 1-3, accent, accent-soft, on-accent, success, warning, danger, notice (`:root` and `.dark` in `app/globals.css`, Tailwind 4 `@theme inline`). [S1]
- No raw hex in components except for data palettes, which are also tokens (`--color-uv-*`). [S1]
- A unit test checks every text token reaches 4.5:1 on every surface in both themes (`lib/design-tokens.test.ts`). [S1]
- One self-hosted variable font with a metric-matched fallback (`app/fonts.ts`); a bare `system-ui` stack fails because it renders differently per OS. [S1]
- A small type scale (Solara: 11, 12, 13, 14, 16, 18, 22 px, headings 650-750 weight), 4 px spacing steps, radii 10 (buttons), 12 (metric), 16 (cards), 20 (dialogs). [S1]
- Buttons: `.btn`, `.btn-primary`, `.btn-ghost`; hover only under `@media (hover: hover)`; press scales to 0.97; disabled is faded and inert. [S1]
- Motion is short (100-200 ms color and transform transitions), nothing auto-rotates or moves on its own, and `prefers-reduced-motion` removes it. [S1]
- Theme: System, Light, Dark, applied before first paint so there is no flash (`components/ThemeInit.tsx`, `lib/theme.ts`). [S1]

## 8. Accessibility

- Keyboard reaches everything; one visible focus ring style (`:where(a, button, summary, [tabindex]):focus-visible` in `app/globals.css`). [S1]
- `scroll-padding-top` matches the sticky header so focused elements are never hidden. [S1, WCAG 2.4.11]
- Tabs use `aria-current` or the tabs pattern; icon buttons have `aria-label`; live regions for async status. [S1]
- Touch targets at least 44 px on phones (32 px only for dense header icons with spacing). [S1, WCAG 2.5.5]
- Every screen passes axe with zero violations in both themes (`tests/harness/capture.ts`). [S1]

## 9. PWA and install polish

- Manifest with name, theme color, 192, 512 and maskable icons, tested (`public/manifest.webmanifest`, `tests/manifest.test.ts`). [S1]
- An app-shell service worker so the installed app opens offline with the last data; navigations network first with a short fallback so no one is pinned to old HTML (`scripts/build-sw.mjs`). [S1]
- Install prompt: one small dismissible card, offered after the user got value, remembered when dismissed, never shown when installed (`components/InstallPrompt.tsx`, `lib/install-prompt.ts`). [S1]
- After an update reloads the app, say so once (`components/UpdateNotice.tsx`). [S1]

## 10. Review checklist

The checklist covers sections 1-9 and 12-21.

- [ ] At most 5 primary destinations, the same on desktop and phone.
- [ ] Avatar opens a menu with Settings, theme or Display, Account and Sign out; guests see Settings and Sign in.
- [ ] Sign-in is a modal; no `/login` page in the main flow.
- [ ] The main question is answered above the fold at 1440x900; desktop uses the width.
- [ ] Onboarding and tips do not push returning users' content down.
- [ ] Every data view has an empty, loading (skeleton), error (retry) and offline state.
- [ ] Every write shows saving, saved and failed; where data lives is stated next to it.
- [ ] Settings is one sectioned dialog with a clear save model.
- [ ] Tokens only, contrast test passes, one bundled font, dark mode has no flash.
- [ ] Motion is short and respects reduced motion; nothing moves on its own.
- [ ] axe clean, keyboard complete, 44 px targets on phones.
- [ ] Manifest and icons valid; installed app opens offline.
- [ ] No horizontal scroll and no truncated key text at 320, 390, 1024 and 1440 px.
- [ ] Ctrl/Cmd+K palette and `?` shortcut list; shortcuts ignore typing; the URL restores the view, filters and open dialog; Back closes dialogs first.
- [ ] Reversible actions use Undo toasts; no `window.confirm()`; optimistic writes roll back visibly.
- [ ] A new user gets value in one screen (sample data or a guided first entry); every list has its own empty state.
- [ ] Lighthouse budgets and a JS budget run in CI; field vitals are collected.
- [ ] Download my data, import, Delete account (or Clear data for guests) and a privacy page exist; where data lives is said in the product.
- [ ] Time zone, date, time, week start and units default to the browser and can be overridden.
- [ ] Styled 404 with a real 404 status, styled error page, OG image, favicon set, one consistent product name.
- [ ] Copy follows `VOICE.md`: verb buttons, no em dash, errors say what was kept.
- [ ] Sign out everywhere, no silent expiry, unsaved-changes guard, local draft autosave.
- [ ] Sentry wired with source maps; cookie-free analytics; CSP allows both.

## 11. How to verify

- Build a UI harness like Solara's: every screen and state rendered with fixed data and a frozen clock, captured at 1440x900 and 390x844 in light and dark, with axe on each (`playwright.harness.config.ts`, `tests/harness/capture.ts`, `tests/harness/freeze.ts`, `tests/harness/dashboard-states.spec.ts`). [S1]
- Look at every screenshot yourself before claiming done; compare before and after side by side. [S1]
- E2E persistence tests against the real backend or its emulator: create, reload, sign out and in, and on a second browser context see the same data; also the offline and failed-save paths (`tests/e2e/signed-in/preferences.e2e.ts`, `tests/e2e/offline.spec.ts`). [S1]
- Test the account menu's keyboard pattern (`tests/harness/account-menu.spec.ts`). [S1]
- Check the live site with the `chrome-devtools-axi` skill after deploy, at both widths. [S1]
- Run Lighthouse with the desktop and mobile presets on the home page and the main app view (median of three) and compare with the section 15 budgets; read the console for CSP errors at the same time. [S9]
- Request a made-up path and check both the page and the HTTP status (`curl -s -o /dev/null -w '%{http_code}'`). [S9]
- Press Ctrl/Cmd+K, `?`, a shortcut inside a text field (must not fire), and Back with a dialog open; reload a filtered view and check it comes back the same. [S3, S4]
- Delete something and undo it with the toast and with Ctrl/Cmd+Z, then fail the network and check the rollback message. [S3, S4]
- Start from an empty account or a fresh browser profile and time how long the first real value takes. [S5, S8]
- Export, clear, import the file and compare; switch the browser locale and time zone (`emulate` in chrome-devtools-axi) and check dates, week start and units. [S5, S6]
- Audit records follow `METHODOLOGY.md`, and each finding links to a screenshot or a code reference. [owner]

## 12. Web-first power use

- Ctrl/Cmd+K opens a command palette on the app's Dialog primitive: search, go to every destination, the main create action, theme, Settings, and sign in or out; arrow keys, Enter and Escape work, and a footer shows those keys. [S4, S5, S6, S7]
  A page with fewer than about five actions (a landing page, a one-screen game) may skip the palette.
- Frequent actions have a single-key or two-key shortcut (`c` create, `g` then `h` home), placed next to the feature that owns it. [S2, S3, S7]
- Shortcuts never fire while typing in an input, textarea, select or contenteditable, and a shortcut for the page underneath does not fire while a dialog is open. [S3, S4]
- Two-key sequences time out after about 1 s and any non-printable key cancels them. [S4]
- Shortcuts are discoverable: key chips beside commands in the palette and menus, in tooltips, `aria-keyshortcuts` on the control, and `?` (Shift+/) opens a dialog listing them all. [S4, S5, S6]
- The URL is the state: the current view, tab, filters, sort, search, selected item and an open detail dialog live in the path or query, so reload, share and Back restore exactly what the user saw. [S3]
- Filter, sort and search changes use `replace`; opening a new view or a detail uses `push`, so Back undoes navigation, not keystrokes. [S3]
- Back (and Android back) closes the top dialog or sheet before it leaves the page, and Escape on a detail view returns to its list. [S1, S3]
- Navigation is a real `<a href>`, so Ctrl/Cmd+click and middle-click open a new tab. [S3, S5]

## 13. Undo over confirm

- Reversible actions (delete an entry, archive, remove from a list, mark done) happen at once and show a toast naming what changed with an Undo button for about 6 s; Ctrl/Cmd+Z runs the same undo while the toast shows. [S3]
- Updates are optimistic and roll back visibly on failure: the previous state returns and the user reads "Could not save, try again" with their input kept. [S1, S4]
- `window.confirm()` is never used: it is unstyled, blocks the page and cannot explain the consequence. [S9]
- A confirm dialog is kept for irreversible or wide actions only (delete account, delete all data, sign out everywhere); it names what is lost, and deleting an account asks the user to type a word or their email. [S3, S7]

## 14. First run

- A new user reaches the core value in one screen and about a minute: either sample data marked "Example" with one tap to clear it, or a guided first entry that is the real first action, not a tour of the UI. [S5, S8]
- Offer at most three ways to start (from scratch, from a template, guided). [S8]
- Every list and filter has its own empty state saying why it is empty and what will appear there, with one action. [S1, S7, S8]
- Onboarding is skippable and resumable, and once done or dismissed it never returns; a checklist can be snoozed. [S1, S5]
- Guests can do the main action before signing up when the app allows guests. [S1, S6]
- First-run hints sit next to the control they explain and go away once it is used. [S6]

## 15. Performance budgets

- Core Web Vitals at the 75th percentile: LCP at most 2.5 s, INP at most 200 ms, CLS at most 0.1. [S9, web.dev/vitals]
- Lighthouse on the home page and the main app view: desktop performance at least 90 and accessibility at least 95, mobile performance at least 80, best practices and SEO at least 90. [S9]
- CI runs Lighthouse on the production build, three runs per page, judged on the median, with desktop and mobile presets, and keeps the reports as artifacts. [S9]
- First-load JS per route has a gzipped budget in a checked-in file (about 200 kB for app pages, 120 kB for a landing page), checked in CI with the size change reported on the PR. [S2, S6, S9]
- Heavy, rarely used code (auth SDKs, charts, editors, dialogs) loads on demand. [S1]
- Real-user vitals are collected in production (Cloudflare Web Analytics reports them without cookies). [S9]

## 16. Data ownership and privacy

- Where data lives is stated in the product at the moment it is created, and local-only apps add that browser storage can be cleared and point to export or sign-in. [S1, S6]
- Settings has a Data section with "Download my data" (JSON with everything the user entered, plus CSV for tables) and an import of that same file. [S6, S9]
- Import warns before it replaces data and offers a backup first. [S6]
- A storage quota or write failure is shown, never swallowed. [S6]
- Signed-in apps offer Delete account in Settings: it says what is deleted and what is kept, asks for typed confirmation, signs out and lands on a plain goodbye page. [S2, S3, S7]
- Guests get "Clear data on this device". [S9]
- A short privacy page, linked from the footer and Settings, says what is stored, where, who can see it, which third parties get what (auth, analytics, error reporting) and how to delete it. [S9]

## 17. Units, locale and time

- Defaults come from the browser: time zone from `Intl.DateTimeFormat().resolvedOptions().timeZone`, date, number and 12/24 h formats from the locale. [S5]
- Settings offers overrides for time zone, date format, time format and week start, each with a "System (detected value)" option as the default. [S5]
- Week start (Sunday or Monday) drives every calendar and weekly stat. [S2, S5]
- Quantities with units (kg/lb, km/mi, cm/ft-in) are stored in one canonical unit and converted for display; the unit is chosen when the first number is entered. [S9]
- Dates and numbers are formatted with `Intl`, never by hand; a relative time ("2 h ago") shows the absolute time in a tooltip. [S5]
- "Today", streaks and day boundaries use the user's time zone, and when the device zone changes the app asks before changing the stored one. [S2]

## 18. Edges: errors, sharing, identity

- Unknown paths show a styled not-found page inside the app's look with Home and Back, and the HTTP status is a real 404, also for single-page apps. [S2, S3, S7]
  The framework's default "This page could not be found." page fails.
- Where it helps, the not-found page suggests where to go next (Cal.com lists popular pages). [S2]
- Errors render a styled error page with Retry and Home and report to error tracking, including a root-level boundary (`global-error`). [S2, S7]
- Every public page has a title, meta description, canonical URL and a 1200x630 Open Graph image; shareable entities get a generated image. [S3, S9]
- Icons: SVG favicon with a 32 px fallback, a 180 px apple-touch-icon, and manifest icons at 192, 512 and maskable. [S1]
- `theme-color` is set for light and dark where the app has both. [S1, S9]
- One product name, spelled the same in the title, wordmark, manifest, OG image, emails and store listing, and the favicon matches the logo. [S9]

## 19. Copy and voice

- In-app copy follows the owner's `writing` skill and its `VOICE.md`: lead with the point, plain words, no hype. [owner]
- Buttons name the action as a verb and object ("Save workout", "Revoke all sessions"), never "OK" or "Submit". [S1, S7]
- Errors say what happened, what was kept and what to do next. [S1, S7]
- Empty and first-run copy says what will appear here, not "No data". [S7]
- One word per concept across the app, and strings live in one module per area so they can be reviewed together (`messages/*.ts`). [S1]
- Sentence case for headings and buttons, and no em dash anywhere, including titles and the manifest. [owner]

## 20. Sessions and unsaved work

- Settings has "Sign out everywhere" with one sentence on what it does (every browser signed out; API tokens unaffected, if the app has them). [S7, S9]
- Apps used on several devices list active sessions (browser, last active, "This device") with Revoke per row. [S7]
- When a session expires the app keeps the user's input, opens the sign-in modal, and finishes the action after sign-in. [S1]
- Unsaved changes warn on close, on in-app navigation and on `beforeunload`. [S1, S6]
- Long-form input autosaves a local draft, debounced and flushed on blur and `visibilitychange`, so a reload or crash loses nothing. [S6]
- Two open tabs stay consistent: a change in one shows in the other when it regains focus. [S6]

## 21. Observability and analytics

- Error tracking (Sentry) runs in the browser and on the server, with release and environment tags, uploaded source maps, PII removed in `beforeSend`, and known noise (extensions, aborted fetches) ignored. [S1, S2, S6]
- Error boundaries report to error tracking and show the section 18 error page. [S2]
- Analytics are cookie-free by default: Cloudflare Web Analytics, loaded only when its token is set so local, CI and test runs send nothing. [S9]
- Anything that sets cookies or identifies users (GA, PostHog) waits for consent and is named on the privacy page. [S8, S9]
- The Content Security Policy allows the analytics and error-tracking hosts the app actually loads; a CSP console error means the data is silently missing. [S9]
- Apps with a backend expose a health endpoint and have an uptime check (OpenPing). [S9]

## Version history

- 1.1 (2026-11-04, claude-opus-5-5 as a Claude Code subagent): source citations on every standard; new sections 12-21 (power use, undo, first run, performance, data ownership, locale, edges, copy, sessions, observability) from S2-S9; checklist and verification extended; Known gaps extended from the 12-app audit; sections 1-11 keep their meaning and numbering.
- 1.0 (2026-11-04, claude-opus-5-5 as a Claude Code subagent, commit `0540a7f`): sections 1-11 distilled from Solara (S1), with Known gaps for FitFlow 7 and Feelium.

## Known gaps (2026-11-04)

### FitFlow 7 (`~/projects/public/fitflow7`, https://fitflow7.n8builds.dev)

- Nine top-level links in the desktop header (Workouts, Calendar, Stats, Challenges, Exercises, History, Insights, Community, Settings); phones hide four behind "More".
  Group into about four (Today, Plan with Calendar and Challenges, Progress with Stats, History and Insights, Library) plus Settings in the avatar menu.
- Signed out, the header has no account control at all: sign-in is buried in Settings (GitHub only) and `src/components/AccountMenu.tsx` returns null.
  Add the guest gear plus a Sign in modal, and a provider a gym user has (Google).
- Persistence is unclear: "Routines and history live only in this browser" appears only on the Settings page, and the "Saved" live region only there.
  State it on the dashboard and after each workout, and show sync state in the header for signed-in users.
- The home page is one 990 px column, 2533 px tall on desktop (2871 px on a phone): onboarding card on top, then today's workout, stats, a challenge banner, a 12-item exercise outline and the full workout list.
  Move onboarding out of the page, put today's workout and the week side by side on desktop, and move the outline and "All workouts" to their own views.
- Settings is one 2297 px scrolling page of cards; convert to a sectioned dialog with Display (theme), Workout defaults, Audio, Data and Account sections.
- No bundled font (falls back to `ui-sans-serif, system-ui`), so it renders as DejaVu on Linux and differently per OS; Vite app, so self-host a variable font.

### Feelium (`~/projects/feelium`, https://feelium.n8builds.dev)

- The "N" avatar in `src/components/top-bar.tsx` is a plain link to `/settings`; make it a menu (name, email, Settings, theme, Sign out, sign out everywhere) with `src/components/ui/dropdown-menu.tsx`, which already exists.
- Desktop Today is a 768 px column (`max-w-3xl` in `src/app/(app)/layout.tsx`) with four stacked 1-5 scales, about 180 px each, so a check-in needs scrolling on a 900 px laptop.
  Use a 2x2 grid of scales at 1024 px and up, and put today's behaviors beside it.
- Save feedback is uneven: behavior rows save optimistically with only an error toast on failure, and Today shows "0 check-ins today" next to selected values.
  Add a quiet per-row "Saved" tick and make the unsaved check-in draft look different from a saved one.
- There is both a `/login` page and `src/components/sign-in-dialog.tsx`; route every sign-in through the modal.
- Settings is a list of sub-pages (`src/components/settings/settings-list.tsx`); fine on phones, but on desktop show the section list and the open section side by side, like Solara's Settings sheet.
- The signed-in app has no visible sync or offline state; add an "updated at" and offline notice like Solara's.

### All apps (2026-11-04 audit, source S9)

Full grades and evidence: `APP_SCORECARD.md` in the private `secret-handling-review` repo.

- No app has a command palette, a `?` shortcut list or an Undo toast; `window.confirm()` is used in Pivot, FitFlow 7, OpenPing and PortfolioRank.
- Only n8builds and portfolio report errors to Sentry; the CSP on Pivot and PortfolioRank blocks the Cloudflare analytics beacon.
- Unknown paths: framework default 404 on Scribe, Sprite Bench and KeysReady, an unstyled one on Cutely Ask, status 200 on FitFlow 7, OpenPing and Who Am I, and a redirect to sign-in on Feelium.
- No Open Graph image on Feelium, FitFlow 7, KeysReady, Pivot, PortfolioRank and Who Am I.

### Pivot (`~/projects/pivot`, https://pivot.n8builds.dev)

- Deleting data uses `window.confirm` (`src/app/settings/page.tsx`); use a dialog that names the loss, and Undo for single deletes.
- Sign-in is GitHub only from the Settings page; add the sign-in modal.
- Light only; add the dark theme.
- Desktop Lighthouse fails with NO_NAVSTART on `/`, which suggests a navigation during load; find it.

### OpenPing (`~/projects/public/open-ping`, https://openping.n8builds.dev)

- Eight sidebar destinations and a phone "More" menu (`src/client/components/AppLayout.tsx`); group to about five.
- The app redirects to a `/login` page while the landing has a sign-in modal; use the modal everywhere.
- System font and dark only; unknown paths return 200.

### PortfolioRank (`~/projects/public/portfolio-rank`, https://portfoliorank.n8builds.dev)

- At 390 px the header overlaps ("Rank" runs into "Top", "Sign in" wraps); emoji serve as nav icons.
- Accounts exist but there is no privacy page or Delete account; screenshot URLs 404 in the console.
- Keyboard voting (arrows and S) exists but is not shown anywhere.

### KeysReady (`~/projects/experiments/auto-repair-shop`, https://app.keysready.n8builds.dev)

- `app.` serves the marketing page; shops and drivers sign in on separate `/login` pages.
- Em dashes in the title, manifest name and hero copy; system font; an auto-rotating hero card.

### Cutely Ask (`~/projects/polish/cutelyaskme`, https://cutelyaskme.nathancwatkins23.workers.dev)

- The 404 renders unstyled; the desktop home is a small card on an empty page.
- One product, three names (Cutely Ask, Date Night, cutelyaskme), and an em dash in the title.
- No privacy page or Delete account; the home route ships about 540 kB of script against its 210 kB budget.

### Smaller sites

- n8builds.dev: mobile Lighthouse 65 (LCP 3.7 s, CLS 0.17, TBT 610 ms); the hero portrait swaps on its own.
- portfolio.n8builds.dev: mobile TBT about 1 s; 30 inline SVGs without accessible names; no privacy page despite GA.
- Scribe: framework default 404 and no analytics.
- Sprite Bench: unlabeled inputs and selects, contrast failures, no favicon, no `h1`.
- Who Am I: no OG image or manifest for a game shared by link.
