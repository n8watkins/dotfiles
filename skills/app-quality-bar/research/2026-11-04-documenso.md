# S7 Documenso (2026-11-04)

Source ID: S7.
App: Documenso, open-source document signing (https://documenso.com, app at https://app.documenso.com).
Repo: github.com/documenso/documenso at `91e73d59281254ad0e258adc861a337c85da60d0` (commit date 2026-11-04).
License: AGPLv3 (`LICENSE`).

## Provenance

- Studied: 2026-11-04, 19:36-19:46 UTC.
- Model: claude-opus-5-5, running as a Claude Code subagent.
- Repo read: shallow clone (`git clone --depth 1`) in the session scratch directory, files read with grep and sed; no code was run.
- Live: https://app.documenso.com/signin at 1440x900, light, signed out.
- Tools: git 2.x, chrome-devtools-axi 0.1.44 (headless Chromium 156), no Lighthouse run on reference apps.
- Evidence: screenshots are kept in the owner's private research repo (paths below), not in this public repo.

## Observations

- Command menu: `apps/remix/app/components/general/app-command-menu.tsx` uses `react-hotkeys-hook`, debounces search 200 ms (L87), searches documents and templates, and has sub-pages for theme and language (L80); `packages/lib/constants/keyboard-shortcuts.ts` defines sequences `N+S` settings, `N+D` documents, `N+T` templates.
- Per-status empty states: `apps/remix/app/components/tables/documents-table-empty-state.tsx` gives each tab its own title and sentence ("No active drafts", "Nothing cancelled", "Documents that a recipient declines to sign will appear here").
- Sessions: `apps/remix/app/routes/_authenticated+/settings+/security.sessions.tsx` lists active sessions with a "Current" badge and a Revoke button per row, plus embed sessions; `components/dialogs/session-logout-all-dialog.tsx` "Revoke all sessions".
- Account deletion: `components/dialogs/account-delete-dialog.tsx` names what is deleted ("all of your documents ... signatures, and all other resources", L103-107), says it is not reversible, requires 2FA off, and asks the user to type their email (L111-122).
- Error pages: `components/general/generic-error-layout.tsx` maps 404 and 500 to a heading, a plain sentence and Go Back and Home buttons (L36-107).
- Sign-in: email and password with providers (screenshot `secret-handling-review/evidence/2026-11-04/reference/app_documenso_com_signin.png`).

## Adopted

- A sessions list with Revoke and Revoke all (section 20).
- Delete account that names the loss and asks for typed confirmation (sections 13 and 16).
- Context-specific empty states (section 14) and one shared 404/500 layout with Back and Home (section 18).

## Not copied

- No code or copy; the separate sign-in page is not adopted (section 5).
