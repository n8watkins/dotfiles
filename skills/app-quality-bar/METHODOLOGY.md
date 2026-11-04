# How quality-bar studies are done

This is the method behind `SKILL.md` and `research/`.
Follow it for every new source study and every app audit, so each standard can be traced to evidence and re-checked.

## What a study covers

- One source per record: an app we learn from (open source or the owner's own) or one audit pass over the owner's apps.
- Read the code at a fixed commit: a shallow clone (`git clone --depth 1`) in the session scratch directory, or `git grep` at `origin/main` for the owner's repos; never modify another session's working tree.
- Visit the live public pages with `chrome-devtools-axi` (or Playwright for batch captures).
- Screens: the home or first screen, sign-in, a made-up path (404), and for apps with a public demo the main view, Settings and one empty state.
- Widths: 1440x900 and 390x844; add 320 and 1024 when checking layout breakpoints.
- Themes: light and dark through `prefers-color-scheme`, plus the in-app theme switch where one exists.
- Signed out only, unless the owner provides a test account; never sign in with real credentials; read signed-in parts from code.
- Measurements for audits: Lighthouse CLI mobile and `--preset=desktop` on the home page (and the main app view when reachable), axe (WCAG 2.1 A/AA) in both themes, HTTP status of the 404 path, console errors, page facts (h1, title, meta, OG image, icons, manifest, fonts, horizontal overflow).

## What a record contains

- File: `research/YYYY-MM-DD-<source>.md`, with a source ID added to `research/SOURCES.md`.
- App name and URLs; repo, exact commit SHA and license as read at that commit.
- Date and time of the study (UTC); live URLs visited with viewport, theme and signed-in state.
- Method: which files were read and how, tool names and versions.
- The model that did the study and how it ran (for example claude-opus-5-5 as a Claude Code subagent).
- Observations with file paths and line numbers, and screenshot paths.
- What we adopt and why, and what we explicitly do not copy.
- If anything is reconstructed after the fact, say so and say from what.

## Evidence and licensing

- We learn patterns; we never copy code, assets or copy text from other projects, and we respect each license (AGPL and commercial files are read only to learn behavior).
- Screenshots live in the owner's private research repo (`secret-handling-review/evidence/YYYY-MM-DD/`), not in this public dotfiles repo; public records reference them by path.
- Screenshots of the owner's own public pages may also be committed to public repos; anything signed in, personal or third-party stays private.
- Never put secrets or personal data in evidence; do not read `.env` files.

## How a finding becomes a standard

- It must be checkable: a reviewer can pass or fail it from a screenshot, a measurement or a code reference, not a taste note.
- It needs at least one cited source: an observed pattern in a studied app, an owner decision, or a published threshold (WCAG, Core Web Vitals).
- Prefer patterns seen in two or more strong apps; a single-source standard says so by citing one ID.
- Write it as one sentence per line, no em dash, and cite sources in brackets at the end (`[S3, S4]`, `[owner]`).
- Keep section numbers stable: add sub-items or new sections; change the meaning of an existing standard only with the owner's OK and a version bump.
- Bump the version in `SKILL.md` (minor for additions, major for changed meaning) and add a line to its Version history.

## How standards are re-verified

- Each app audit (scorecard) grades every section pass, partial or fail with linked evidence, so a regression shows up as a changed grade.
- Re-run a source study when a cited file moves or the app changes a lot; record the new commit in a new dated record rather than editing the old one.
- When a standard is found wrong or impractical in use, record why in the next study and change it through the version process above.
