---
name: gpu-jobs
description: Use when a task would run a render, a browser test, a model or any other job on the PC's graphics card. Gives the rules for sharing the one card and how to measure the job with gpu-run.
---

# Jobs on the graphics card

- Run every card job through `gpu-run --label "<what>" --kind <kind> -- <command>`: it waits for the shared lock (`/tmp/test-gpu-1.lock`, the same one the party-games test helper and `flock` take), samples the card and logs one line to `~/.local/state/gpu/jobs.jsonl`.
- One heavy job at a time; never add a second lock or raise `TEST_GPU_JOBS` to get around a wait.
- Select the discrete card by name ("RX 7800") in every tool (Blender, Mesa, Vulkan, NCNN); never the integrated Radeon, which shows up as a second device.
- Blender stays off the card until the owner says otherwise; when he does, follow the staged retry in `GPU-PLAYBOOK.md` (card only, HIP-RT off).
- Heavy jobs (renders, image models) only when he is away: add `--only-when-idle 15`; exit 4 means he is using the PC, so try later.
- Before changing how a job uses the card, run it once on the card and once with `--cpu` under the same label; `gpu-run --report` shows the speed-up.
- The off switch: `gpu-run --off "<reason>"` stops every GPU job (exit 3) and `TEST_NO_GPU=1` keeps test browsers in software; switch it back with `gpu-run --on` only when the owner says so.
- After a driver error (black screen, "driver timeout", a crash in an `amd*.dll`): stop, run `gpu-run --off "<what happened>"`, check `gpu-run --events --since <date>`, add it to the playbook's incident log and tell the owner.
- Never change the Windows TDR registry keys (`TdrDelay` and the like); they hide driver faults.
- Test browsers on the card stay headless on a private Xvfb display, never the owner's desktop.
- Record results in `GPU-PLAYBOOK.md` in the private ops repo (method, results table, claimed against measured); cite the `gpu-run` log line for each number.
