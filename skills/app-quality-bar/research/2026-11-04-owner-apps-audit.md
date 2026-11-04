# S9 Owner app audit (2026-11-04)

Source ID: S9.
What: an audit of the owner's 12 live web apps against this playbook, which also surfaced patterns worth copying from the owner's own repos.
Full scorecard (per-app grades, Lighthouse numbers, screenshots): `APP_SCORECARD.md` in the owner's private research repo `secret-handling-review`, evidence under `evidence/2026-11-04/`.
This public record keeps only what is visible in the public repos and on the public pages.

## Provenance

- Studied: 2026-11-04, 19:35-20:05 UTC.
- Model: claude-opus-5-5, running as a Claude Code subagent.
- Signed in: no; signed-in parts read from code at each repo's `origin/main`.
- Viewports: 1440x900 and 390x844 (iPhone 13 emulation), `prefers-color-scheme` light and dark, plus a made-up path for the 404 check.
- Tools: Playwright 1.56.1 with Chromium 156 and `@axe-core/playwright` (WCAG 2.1 A/AA tags) for screenshots and page facts; Lighthouse 13.6.0 CLI (mobile default and `--preset=desktop`); chrome-devtools-axi 0.1.44 `lighthouse` (desktop accessibility, best practices, SEO); `git grep` at `origin/main`.

## Repos read (origin/main)

| App | Repo | SHA |
| --- | --- | --- |
| n8builds.dev | n8watkins/n8builds-web | `246e0bd` |
| portfolio.n8builds.dev | n8watkins/dev-portfolio | `b289f9f` |
| scribe.n8builds.dev | n8watkins/scribe-web | `1633d42` |
| sprite-bench.n8builds.dev | n8watkins/sprite-bench | `0b26922` |
| pivot.n8builds.dev | n8watkins/pivot | `ca742b5` |
| feelium.n8builds.dev | n8watkins/feelium | `71bee5d` |
| fitflow7.n8builds.dev | n8watkins/fitflow7 | `a65edac` |
| portfoliorank.n8builds.dev | n8watkins/portfolio-rank | `b86e39c` |
| app.keysready.n8builds.dev | n8watkins/keysready | `d92c845` |
| cutelyaskme.nathancwatkins23.workers.dev | n8watkins/cutelyaskme | `8436824` |
| openping.n8builds.dev | n8watkins/open-ping | `d418dcc` |
| who-am-i-game.nathancwatkins23.workers.dev | n8watkins/who-am-i | `0e14d72` |

## Patterns adopted into the playbook

- Lighthouse budgets in CI: n8builds-web `scripts/lighthouse.mjs` (median of 3, desktop and mobile budgets, error vs warn) run by the `lighthouse` job in `.github/workflows/ci.yml`; dev-portfolio `lighthouserc.json`. (Section 15.)
- A JS budget file: cutelyaskme `bundle-budget.json` (gzipped first-load kB per route, checked by `npm run size`). (Section 15.)
- Cookie-free analytics loaded only when a token is set: n8builds-web `components/WebAnalytics.tsx`; consent for GA in `lib/consent.ts`. (Section 21.)
- Sign out everywhere with a sentence on what it does: open-ping `src/client/pages/settings/Security.tsx` (L50-98), fitflow7 `src/pages/Settings.tsx` (L120-129). (Section 20.)
- Units chosen explicitly: fitflow7 `src/pages/Settings.tsx` L625 "Imperial (lb, ft/in)" / "Metric (kg, cm)". (Section 17.)
- Export and import of all data: fitflow7 `exportData`/`importData` in `src/lib/storage.ts`; pivot `src/app/api/export/route.ts` with "Download my data" in `src/app/settings/page.tsx` L105-107; feelium `src/app/(app)/settings/data/page.tsx`. (Section 16.)
- A 404 in the product's voice with a real 404 status: pivot ("This path does not lead to a pivot.", `src/app/not-found.tsx`). (Section 18.)

## Anti-patterns that became standards

- `window.confirm()` for destructive actions: pivot `src/app/settings/page.tsx` L41, open-ping `Security.tsx` L50, fitflow7 `src/pages/Challenges.tsx`, `RoutineEditor.tsx`. (Section 13.)
- A CSP that blocks the app's own analytics beacon (console error on pivot and portfoliorank home pages). (Section 21.)
- Framework default 404 pages, and single-page apps answering 200 for unknown paths. (Section 18.)
- Em dashes in page titles and manifest names, against the owner's rule. (Section 19.)

## Not copied

- Nothing from outside the owner's repos; all of the above is the owner's own code.
