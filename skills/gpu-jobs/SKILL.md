---
name: gpu-jobs
description: Use when a task would run a render, a browser test, a model or any other job on the PC's graphics card. Gives the rules for sharing the one card and how to measure the job with gpu-run.
---

# Jobs on the graphics card

- Run every card job through `gpu-run --label "<what>" --kind <kind> -- <command>`: it waits for card tokens (`/tmp/test-gpu-<n>.lock`, the same files the party-games test helper takes), samples the card, its temperature and fan, and logs one line to `~/.local/state/gpu/jobs.jsonl`.
- The card counts browsers, not jobs: a pool of 3 tokens, one per headless WebGL browser that may draw at once (`TEST_GPU_JOBS`; real suites ran fine to about six browsers and failed from eight, `GPU-PLAYBOOK.md`, "How many jobs at once").
  A job takes 1 token; a job that runs several card browsers side by side asks for more with `--tokens N` (the pre-deploy gate holds 3 by itself); a heavy job (`--kind blender`, `image` or `model`) takes them all, so nothing draws beside a render.
  Whatever the command starts draws only on its job's tokens (passed down in `TEST_GPU_TOKENS`), never on more.
  Only the owner raises the pool; never add another lock or raise `TEST_GPU_JOBS` to get around a wait.
- Before it starts, a job waits until the card can take it: load averaged under 70% over 10 s, 2 GB of video memory free, under 80 C, and no driver event in the last 30 minutes.
  It says why it waits; exit 6 means the card did not settle within `--admit-wait` (default 30 minutes), so look at what is loading it instead of rerunning.
- Add `--max-temp 85` to long or heavy jobs: it refuses (exit 5) while the card is hotter than that, and stops the job (exit 5, `stopped_for_heat` in the log) after three readings in a row above it.
  A stopped job means the card needs to cool; do not just rerun it.
- Select the discrete card by name ("RX 7800") in every tool (Blender, Mesa, Vulkan, NCNN); never the integrated Radeon, which shows up as a second device.
- Blender stays off the card until the owner says otherwise; when he does, follow the staged retry in `GPU-PLAYBOOK.md` (card only, HIP-RT off).
- Heavy jobs (renders, image models) only when he is away: add `--only-when-idle 15`; exit 4 means he is using the PC, so try later.
- Before changing how a job uses the card, run it once on the card and once with `--cpu` under the same label; `gpu-run --report` shows the speed-up.
- The off switch: `gpu-run --off "<reason>"` stops every GPU job (exit 3) and `TEST_NO_GPU=1` keeps test browsers in software; switch it back with `gpu-run --on` only when the owner says so.
- After a driver error (black screen, "driver timeout", a crash in an `amd*.dll`): stop, run `gpu-run --off "<what happened>"` (gpu-run does this itself when a driver event falls inside a job's own time window), check `gpu-run --events --since <date>`, add it to the playbook's incident log and tell the owner.
- Never change the Windows TDR registry keys (`TdrDelay` and the like); they hide driver faults.
- Test browsers on the card stay headless on a private Xvfb display, never the owner's desktop.
- Record results in `GPU-PLAYBOOK.md` in the private ops repo (method, results table, claimed against measured); cite the `gpu-run` log line for each number.
