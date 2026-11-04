# S8 Formbricks (2026-11-04)

Source ID: S8.
App: Formbricks, open-source surveys (https://formbricks.com, app at https://app.formbricks.com).
Repo: github.com/formbricks/formbricks at `7cddb162bb4615b68561d90a7dbde4c5985213f0` (commit date 2026-11-04).
License: AGPLv3, except `apps/web/modules/ee` (commercial) and several `packages/*` (MIT) (`LICENSE`).

## Provenance

- Studied: 2026-11-04, 19:36-19:48 UTC.
- Model: claude-opus-5-5, running as a Claude Code subagent.
- Repo read: shallow clone (`git clone --depth 1`) in the session scratch directory, files read with grep and sed; no code was run.
- Live: https://app.formbricks.com/auth/login at 1440x900, light, signed out.
- Tools: git 2.x, chrome-devtools-axi 0.1.44 (headless Chromium 156), no Lighthouse run on reference apps.
- Evidence: screenshots are kept in the owner's private research repo (paths below), not in this public repo.

## Observations

- First survey in onboarding: `apps/web/app/(app)/(onboarding)/organizations/[organizationId]/workspaces/new/survey/components/create-first-survey.tsx` offers three paths, "scratch", "template" and "ai" (`TOnboardingSurveyPath`, L16), each going straight into a real survey (L52-88).
- Template gallery as a first-run path: `.../workspaces/new/templates/components/xm-template-list.tsx`.
- Shared empty state component: `apps/web/modules/ui/components/empty-state/index.tsx`, plus feature-specific ones (`workflows-empty-state.tsx`, `EmptyInAppSurveys.tsx`).
- Analytics: PostHog identify components under `apps/web/app/posthog/`; Sentry via `apps/web/instrumentation.ts` and `instrumentation-client.ts`.
- Sign-in: email plus Google, GitHub, Microsoft (screenshot `secret-handling-review/evidence/2026-11-04/reference/app_formbricks_com_auth_login.png`).

## Adopted

- At most three starting paths where the first one is the real first action (section 14).
- One shared empty state component (section 14).

## Not copied

- No code or copy; ee-licensed files were not opened.
- Identified product analytics: our default is cookie-free Cloudflare Web Analytics (section 21).
