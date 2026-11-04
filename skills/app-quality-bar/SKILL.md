---
name: app-quality-bar
description: Use when building, redesigning or reviewing the UI/UX of one of the owner's web apps (FitFlow 7, Feelium, Solara or a new one). The checkable quality bar distilled from Solara, how to verify it, and the known gaps per app.
---

# App quality bar

The owner's apps should feel like Solara: you always know where you are, where things live, and that your data is kept.
Solara (github.com/n8watkins/solara, live at https://solara-uv.web.app/app/) is the reference; paths below are on its `main`.
Every item is a check you can pass or fail, not a taste note.
For a taste-driven or sweeping change, show a desktop preview first (then mobile) with screenshots and get approval, as the rules say.

## 1. App shell and navigation

- One shell component owns the frame: sticky header, optional view tabs, one centered main column (`components/AppShell.tsx`).
- Design desktop first, then phone: the column is about 900 px and widens to about 1240 px at 1024 px and up, with real multi-column layouts there, never one long phone column on a wide screen (`.dash-columns` in `app/globals.css`).
- At most 3-5 top-level destinations; everything else is a section, a dialog or Settings.
  On phones the same destinations sit in a bottom tab bar or tabs under the header; a "More" drawer hiding half the app fails.
- The header, left to right: wordmark (goes home), the current context (Solara's place picker), then compact status and the account control on the right (`components/Header.tsx`, `Header.module.css`).
- Signed in, the right edge is an avatar button (photo or initial) that opens a menu: name and email, Settings, Account, Sign out in red (`components/AccountMenu.tsx`).
  It follows the WAI-ARIA menu button pattern: arrow keys, Home/End, Escape returns focus, outside click closes (`lib/roving-focus.ts`, `lib/use-outside-click.ts`).
  An avatar that is just a link to a settings page fails.
- Signed out, the same spot shows a Settings gear and a "Sign in" button, so theme and preferences are one tap away for guests too.
- Settings opens from anywhere through one opener (`lib/open-settings.ts`, `components/SettingsHost.tsx`), not by navigating away from the task.
- The page has exactly one `h1`; when the header and tab already say where you are, it can be visually hidden (`sr-only` in AppShell).
- Header content never truncates the most important thing: at 320-390 px drop secondary chips first (Solara hides the UV chip so the city fits).

## 2. Information architecture and density

- The first screen answers the app's main question without scrolling at 1440x900 and gets close at 390x844 (Solara: "Today at a glance" summary, then the chart beside the activity plan).
- Order a page by frequency of use: today's primary action and status first, setup and rare actions last or in Settings.
- One-time things (onboarding, tips, install prompts) never sit above the main content for returning users; Solara runs onboarding as its own 3-step flow, then shows one static, dismissible tip per visit (`lib/tips.ts`).
- Say a thing once: one disclaimer line, one Add button when a list is empty, no badge plus heading plus note repeating "done for today".
- Long lists collapse or paginate; a reference list (all exercises, all workouts) is its own view or a dialog, not appended under the dashboard.
- Plain words over jargon on cards; numbers carry their unit and a label.
- Use an SVG icon set (lucide-react) for UI chrome; emoji only for user content such as activity identity.

## 3. States: empty, loading, error, offline, saving

- Empty: one friendly line of what goes here, one primary action (`components/dashboard/ActivityEmptyState.tsx`).
- Loading: a skeleton shaped like the real layout so nothing jumps, with `role="status"` and hidden text (`components/Skeleton.tsx`); never a blank page or a lone spinner for the main view.
- A returning user sees their last data at once from a local copy while the network confirms (`lib/cached-account.ts`).
- Errors say what happened, that nothing was lost, and offer Retry (`AccountLoadError` in `components/AccountStatus.tsx`, `components/ErrorBoundary.tsx`).
- Offline and stale data are named with an "updated at" time (`components/ForecastNotice.tsx`, `messages/app.ts`), and edits are disabled with a reason rather than failing silently.
- Persistence is always visible:
  - say where data lives ("saved in this browser; sign in to keep it on every device") wherever a guest creates data, not only in Settings;
  - saving shows "Saving..." on the button, then a confirmation; a failed save says "Could not save, try again" and keeps the user's input;
  - partial failure is explicit ("Saved on this device, but cloud sync failed", `syncFailed` in `messages/dashboard.ts`);
  - signed-in apps with sync show a sync state (synced, syncing, error) in the header or avatar, visible without opening Settings.
- App-wide notices use one banner component with tones (notice, info, error), `role="status"` or `role="alert"`, and an action (`components/AppNotice.tsx`).

## 4. Forms and settings

- Settings is one dialog with a left section list on desktop and a tab bar on phones, a fixed height so switching sections does not resize it, and full screen on phones (`components/PreferencesModal.tsx`, `components/settings/SettingsTabs.tsx`, `Dialog` variant `sheet`).
- Each section has a title, a one-line description and grouped cards (`components/settings/SettingsCard.tsx`); a 2000 px single scrolling settings page fails.
- Pick one save model per surface and make it obvious:
  - a draft with Cancel and "Save settings" in a sticky footer, plus "Discard unsaved changes?" on close (`lib/settings.ts` `isSettingsDraftDirty`);
  - or save-as-you-go, where every change shows a per-control "Saved" or an error that reverts visibly.
- Inputs: labels always visible, errors next to the field in words, autocomplete with keyboard and screen reader support (`components/PlaceSearch.tsx`).
- Destructive actions sit in their own danger group and confirm in a dialog that names what is lost.

## 5. Sign-in

- Sign-in is a modal over the current page, never a separate login page (owner preference); deep links like `?signin` open the modal.
- It offers the provider buttons and a clear "Continue without an account" when the app supports guests; reuse the copy and card layout of `components/SignInScreen.tsx`, which in Solara is still a full screen, inside the modal.
- After sign-in the user lands back where they were, and a guest's data is merged or the user is told exactly what was not carried over (`components/GuestPlanNotice.tsx`).

## 6. Dialogs and overlays

- One modal primitive on the native `<dialog>` with `showModal()`: focus trap, Escape and Android back route through `onClose`, body scroll lock, focus returns to the opener (`components/Dialog.tsx`, `lib/useBodyScrollLock.ts`).
- Variants: `card`, `narrow`, `sheet`; non-modal details use a bottom sheet (`components/BottomSheet.tsx`).
- Close button top right, primary action bottom right, safe-area padding on phones (`env(safe-area-inset-*)`).

## 7. Visual tokens, type and motion

- Colors are semantic tokens defined once with light and dark values: surface, card, metric, line, ink 1-3, accent, accent-soft, on-accent, success, warning, danger, notice (`:root` and `.dark` in `app/globals.css`, Tailwind 4 `@theme inline`).
- No raw hex in components except for data palettes, which are also tokens (`--color-uv-*`).
- A unit test checks every text token reaches 4.5:1 on every surface in both themes (`lib/design-tokens.test.ts`).
- One self-hosted variable font with a metric-matched fallback (`app/fonts.ts`); a bare `system-ui` stack fails because it renders differently per OS.
- A small type scale (Solara: 11, 12, 13, 14, 16, 18, 22 px, headings 650-750 weight), 4 px spacing steps, radii 10 (buttons), 12 (metric), 16 (cards), 20 (dialogs).
- Buttons: `.btn`, `.btn-primary`, `.btn-ghost`; hover only under `@media (hover: hover)`; press scales to 0.97; disabled is faded and inert.
- Motion is short (100-200 ms color and transform transitions), nothing auto-rotates or moves on its own, and `prefers-reduced-motion` removes it.
- Theme: System, Light, Dark, applied before first paint so there is no flash (`components/ThemeInit.tsx`, `lib/theme.ts`).

## 8. Accessibility

- Keyboard reaches everything; one visible focus ring style (`:where(a, button, summary, [tabindex]):focus-visible` in `app/globals.css`).
- `scroll-padding-top` matches the sticky header so focused elements are never hidden (WCAG 2.4.11).
- Tabs use `aria-current` or the tabs pattern; icon buttons have `aria-label`; live regions for async status.
- Touch targets at least 44 px on phones (32 px only for dense header icons with spacing).
- Every screen passes axe with zero violations in both themes (`tests/harness/capture.ts`).

## 9. PWA and install polish

- Manifest with name, theme color, 192, 512 and maskable icons, tested (`public/manifest.webmanifest`, `tests/manifest.test.ts`).
- An app-shell service worker so the installed app opens offline with the last data; navigations network first with a short fallback so no one is pinned to old HTML (`scripts/build-sw.mjs`).
- Install prompt: one small dismissible card, offered after the user got value, remembered when dismissed, never shown when installed (`components/InstallPrompt.tsx`, `lib/install-prompt.ts`).
- After an update reloads the app, say so once (`components/UpdateNotice.tsx`).

## 10. Review checklist

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

## 11. How to verify

- Build a UI harness like Solara's: every screen and state rendered with fixed data and a frozen clock, captured at 1440x900 and 390x844 in light and dark, with axe on each (`playwright.harness.config.ts`, `tests/harness/capture.ts`, `tests/harness/freeze.ts`, `tests/harness/dashboard-states.spec.ts`).
- Look at every screenshot yourself before claiming done; compare before and after side by side.
- E2E persistence tests against the real backend or its emulator: create, reload, sign out and in, and on a second browser context see the same data; also the offline and failed-save paths (`tests/e2e/signed-in/preferences.e2e.ts`, `tests/e2e/offline.spec.ts`).
- Test the account menu's keyboard pattern (`tests/harness/account-menu.spec.ts`).
- Check the live site with the `chrome-devtools-axi` skill after deploy, at both widths.

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
