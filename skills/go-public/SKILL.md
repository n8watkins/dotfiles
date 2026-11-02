---
name: go-public
description: Use before making a private GitHub repository public. Scans the full git history for secrets and checks README, license and description first.
---

# Making a repository public

Making a repository public publishes its entire git history, not just the current files.

1. Clone a mirror: `git clone --mirror https://github.com/<owner>/<repo>.git`.
2. List env-like files ever committed: `git log --all --name-only --format= | grep -E '(^|/)\.env($|\.)|\.pem$|id_rsa|credentials|service-account'` (ignore `.env.example`).
3. Search added lines in all history for key shapes: OpenAI/Stripe (`sk-`, `sk_live_`, `rk_live_`), Google (`AIza`), GitHub (`ghp_`, `github_pat_`), Resend (`re_`), Slack (`xox[bp]-`), AWS (`AKIA`), private keys (`BEGIN … PRIVATE KEY`), JWTs, database URLs with passwords, webhook secrets (`whsec_`).
   Print matches masked; never print full values.
4. For each hit, decide: placeholder or fake (fine), public-by-design like a Firebase web key (fine, note it), or real (stop: rotate the key, then rewrite history with `uvx git-filter-repo` or keep the repo private).
5. Check the repository has a README that says what it is, a description, and a license; ask the owner which license if none (MIT is their usual choice).
6. Only then run `gh repo edit <owner>/<repo> --visibility public --accept-visibility-change-consequences`.
