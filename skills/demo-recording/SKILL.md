---
name: demo-recording
description: Use when recording, re-recording or reviewing an automated product demo clip (Playwright) of one of the owner's Chrome extensions or web apps, for a build page, homepage card, store listing or README. Covers the demo-kit pipeline (~/projects/tools/demo-kit), pre-flight (latest build, throwaway profile, fixtures), camera and cursor rules, the storyboard, the review checklist and past mistakes.
---

# Recording product demo clips

Version 1.1, 2026-11-09.
Written after the owner's critique of the first extension clips (TL;DW, VoiceDock, TubeVault) on 2026-11-09.

**The pipeline is demo-kit:** https://github.com/n8watkins/demo-kit, local clone `~/projects/tools/demo-kit`.
Every new or re-recorded clip is a storyboard file in `demo-kit/storyboards/<product>.ts`, recorded and rendered with its CLI; its README has the API, the commands and troubleshooting.
The older scripts in n8builds-web (`scripts/product-clips/`, `scripts/scribe-tour/`) made the 2026-11-09 clips and are not used for new ones.

```bash
cd ~/projects/tools/demo-kit
demo-kit record storyboards/<product>.ts --expect <repo>@origin/<default>   # pre-flight, then the take
demo-kit plan takes/<take> --strict                                         # camera plan; fix the storyboard until the desktop plan has no warnings
demo-kit render takes/<take>                                                # desktop 1280x800 + phone 390x760: .mp4, .webm, -poster.webp
demo-kit usage note <take> --tokens "<subagent totals>"                     # see "Usage" below
```

## The decision: our own small module, rendered with Remotion

No existing tool does the whole job, so we keep a small module of our own and use existing pieces where they fit.

| Option | What it gives | Why it is not the answer on its own |
| --- | --- | --- |
| Playwright 1.59+ `page.screencast` with `showActions({ cursor: 'pointer', style })` | A recording API with frame callbacks and an animated pointer between actions. | The decoration is test-report styled (highlight box, action titles), it has no camera, and frames default to fitting 800x800 unless `size` is set. Use `screencast.start({ onFrame, size })` as the capture API, not its decorations. |
| playwright-recast | Post-processes Playwright traces into a video with an eased cursor overlay, click ripples and zoom. | Works from trace screenshots, which are too small for a sharp 2x-2.5x zoom, and it is a young project. Closest prior art for the design. |
| pw-cursor-overlay, mouse-helper, qa-hud | Inject a dot or arrow and a ripple into the page. | Tiny or unmaintained packages; the cursor scales with the camera zoom; it can sit under top-layer UI. |
| ghost-cursor and its Playwright forks | Human-like Bezier mouse paths. | Built to look human to bot detection, with overshoot and jitter; a demo wants calm, predictable glides. Not needed. |
| Screen Studio, Cursorful, Tella, Arcade, OpenScreen, Recordly, Screenize | Polished auto-zoom and cursor smoothing. | Interactive GUI recorders (mostly macOS or in-browser), no API to feed a scripted take and an event log. Use them as the visual reference for how a good clip feels. |
| ffmpeg `zoompan` (our `camera.mjs`) | Eased zoom and pan with no extra dependency. | Rounds the crop window to whole pixels, so slow pans and zooms shake (FFmpeg ticket #4298, open since 2015). Fine for a rough draft, not for a final. |
| Remotion | React compositions rendered frame by frame in Chromium, with subpixel CSS transforms and `<OffthreadVideo>`. | The renderer we use. Free for individuals and companies of up to 3 people; re-check the license if that changes. |

So the pipeline is:

1. **Record** the take with Playwright at 1280x800 CSS and device scale factor 2 (2560x1600 frames), driving the real mouse along eased paths, with no cursor drawn in the page.
2. **Log** every cursor sample, press and focus target with a timestamp on the same clock as the frames (`events.json`).
3. **Plan** the camera: a pure function turns the log into a camera path (`camera.json`) following the rules below, with unit tests for the rules.
4. **Render** with Remotion: the take, transformed by the camera path, with the cursor and click ripples drawn on top at a constant on-screen size; one composition at 1280x800 and one phone cut at 390x760.
5. **Encode** the looping seam, VP9 WebM, H.264 MP4 and WebP poster (demo-kit's `src/render/encode.ts`, ported from `encode.sh`).

### Module spec

Built as demo-kit (above); this was the spec it was built from, and its names map onto demo-kit's API (`take.glide`, `take.press`, `take.select`, `take.focus`, `take.cut`, `planCamera`, the Remotion `Clip`).

- `driver.mjs`, the recording side:
  - `startTake(page)` starts `page.screencast.start({ onFrame, size: { width: 2560, height: 1600 } })` (or CDP `Page.startScreencast` on older Playwright) and keeps each frame with its timestamp in epoch milliseconds.
  - `glide(page, to, { ms })` moves the real mouse along an eased path (ease-in-out cubic, with a slight arc) in steps of about 16 ms, so hover states happen for real, and logs `{ t, type: 'cursor', x, y }` for each step.
  - `press(page, target)` glides there, dwells 200 ms, logs `press`, clicks for real, and holds 300 ms.
  - `drag(page, from, to)` does the same for a text selection, logging `down`, the path and `up`.
  - `focus(name, box, { kind })` logs a focus target: `kind` is `read` (text to read), `action` (a control about to be used), `result` (what appeared) or `context` (a whole panel or page).
  - `cut()` marks a stretch to drop (page loads, model warm-up).
- `events.json`: `{ source: { width, height, scale }, frames: [...], events: [{ t, type, ... }] }`, all times in take seconds after cuts.
- `camera.mjs`, a pure function `planCamera(events, { output, display })` that returns keyframes `{ t, cx, cy, zoom, ease }` and a sampler `cameraAt(t)`, with unit tests that assert the camera rules (never below base zoom, never above focus cap, holds respected, still at every press).
- `remotion/Clip.tsx`: `<OffthreadVideo>` of the take inside a container with `transform: scale(zoom) translate(...)` from `cameraAt(frame / fps)`, plus `<Cursor>` and `<Ripple>` drawn from the event log in output pixels; compositions `Desktop` (1280x800) and `Phone` (390x760, its own camera plan from the same log).

## Pre-flight checklist

Do every item before the first take, and again before a re-take on another day.

1. **Latest build.** In the product repo: `git fetch`, be on the default branch, 0 commits behind, clean tree.
   If the extension loads from a build folder (`dist/`), rebuild it now; a build folder is never trusted as current.
2. **Assert the build inside the take script**, so a stale build fails the run instead of making a clip (demo-kit's pre-flight does all of this: `--expect <repo>@<ref>`, or `extension.expect` in the storyboard, with `forbid` for old names):
   - read `chrome.runtime.getManifest()` from the service worker and compare `name`, `version` and `action.default_title` with `git show origin/<default>:<path>/manifest.json`;
   - fetch the action icon from `chrome-extension://<id>/<icon path>` and compare its hash with the icon on the default branch;
   - grep the loaded folder for the product's old names (for example the pre-rebrand names) and fail on a hit.
3. **Throwaway profile.** `launchPersistentContext` on a new empty folder per take, the extension loaded with `--disable-extensions-except` and `--load-extension`, and the folder moved to the trash afterwards.
   Native messaging hosts go in `<profile>/NativeMessagingHosts`, never system-wide.
4. **Seed demo data** before the take starts (storage, settings, keys), through the service worker or the options page, never on camera unless setup is the story.
   Demo data looks real but is invented: no personal names, emails, keys or tokens.
5. **No live network.** Route everything: `context.route('**', ...)` aborts any host not on the allow-list, and pages and APIs come from fixtures (`route.fulfill`, `routeFromHAR`) or a local static server.
   Use a fixture page we wrote or a public-domain or CC-licensed text for articles, never a real news site.
   Local services (Piper, Kokoro, a native helper) are allowed when they are warmed before the take.
6. **Sharp frames.** Check the take's frame size with `ffprobe` (2560x1600 for a 1280x800 take at scale 2).
   If frames come out at 1280 wide, launch with `--force-device-scale-factor=2`, `viewport: null` and `--window-size=1280,800` instead of the context option.
   For a focus zoom above 2.0, record at scale 3 (3840x2400) or accept slight softness.
7. **Clean screen.** Dark or light theme chosen on purpose, consent banners and dev overlays hidden, fonts loaded (`document.fonts.ready`), notifications off, audio muted.
8. **Popups.** A tab screencast cannot see the real action popup or the toolbar.
   If the story is "click the toolbar icon", record the whole browser window instead (headed under Xvfb, `ffmpeg -f x11grab`) and open the popup with `chrome.action.openPopup()` from the service worker (Chrome 127+; needs a focused window, verify on first use).
   Otherwise show the popup page in a tab only when the clip makes clear it is the extension's panel; never present a centred card on a blank page as if it were the toolbar popup.

## Camera rules

- **Base zoom 1.15-1.3x, never 1.0** after the first second.
  The wide shot is framed on the area where the action happens (the article column, the video and its panel), not the whole viewport.
- **Focus zoom 2.0-2.5x on text the viewer must read.**
  Choose it from readability, not from the box size: on the display where the clip is shown, the target's text should be at least 14 px tall.
  `zoom = clamp(14 / (fontPx * displayWidth / 1280), base, 2.5)`; for 16 px text in a 640 px wide homepage card that is 1.75, rounded up to at least 2.0 for text that is the point of the clip.
- **Never zoom on tiny UI by itself.**
  A small control (a settings toggle, an icon button) is framed with its panel or section, at most about 1.6x, and settings screens stay at base zoom unless one value change is the story.
  The framing window is never narrower than `1280 / maxZoom` CSS px.
- **Stay zoomed while the action moves.**
  When the next target is near (within one frame height at the current zoom), pan at the same zoom instead of pulling back and zooming in again.
  Zoom further only for the moment that matters (a press, a result appearing), then settle back to the reading zoom.
- **Ease every move.** Ease-in-out (cubic or smootherstep), 0.7-1.0 s for a pan, 0.9-1.3 s for a zoom change, one move at a time.
- **The camera arrives before the click.** It settles at least 300 ms before a press and holds still through it; the result's reveal is on camera.
- **Hold long enough to read.** At least 1.5 s on any focus, and about 250 ms per word for text the viewer should read (a two-line highlight: 3-4 s).
- **Follow the cursor softly.** Inside a focus, the camera only pans when the cursor leaves the middle 60% of the frame, and it lags the cursor by about 150 ms.
- **Pull back at the end** to the opening framing, so the loop seam crossfades between two matching wide shots.
- **Subpixel only.** No `zoompan` for finals; the renderer must place the window with fractional pixels so slow moves do not shake.
- **Whole lines when they read.** When a whole text block fits at a smaller zoom that still makes its text 14 px on the display, use that zoom instead of 2.0x, so no line is cut at the frame's edge (an 18 px, 680 px column on a 640 px card: 1.76x).
- **Edges between lines.** Nudge each framing up or down (up to 15% of its height) so the frame's top and bottom edges fall between text lines, never through a heading, and no sliver of a line sits in a corner.
- **A control is held through its press**, at least 1.0 s; an emphasised press goes to 2.5x (the top of the reading range) and settles back after.
- **Never chase a resting cursor.** Follow only a moving cursor or a tracked element; pan only along the axis the subject left, and skip nudges under about 30 px.
- **The phone cut fills the portrait frame** (no bars) and keeps text at 14 px on a 390 px screen, so it is a crop of the desktop take; it follows the cursor even at its base zoom, because its window shows only a third of the page.

## Cursor rules

- **Always visible** from the first frame, drawn in post at a constant on-screen size whatever the zoom: about 28-32 px tall in the 1280x800 output and 22 px in the phone cut.
- **Arrow style:** white with a dark 1.5 px outline and a soft shadow, tip exactly on the logged point; an I-beam only while selecting text.
- **Smooth, calm movement:** ease-in-out, a slight arc, duration by distance (`clamp(350 + 0.6 * px, 400, 1100)` ms), no overshoot or jitter.
- **Click indication:** a 200 ms dwell, a press (arrow scales to 0.88 for 120 ms), and a ripple ring from 8 px to 36 px radius over 450 ms in the product's accent colour at about 40% opacity, centred on the tip.
- **Real input underneath:** the overlay is only a picture; every click, drag and hover is a real Playwright mouse event along the same path, so hover states and selection highlights are genuine.
- **Rest out of the way, in the shot:** after an action, drift the cursor a little aside (never over text being read or the result), to a point the next framing still shows (`take.rest({ beside: target })`); `demo-kit plan` warns when the cursor is out of frame.

## Storyboard template

Write the storyboard before writing the take script, and put it at the top of the script as a comment.

```
Clip: <product> - <the one thing it shows>
Where it plays: <page, card width in px>   Length: <8-20 s>   Loop: yes
Build: <repo>@<commit> manifest <version>   Fixtures: <list>   Seed: <list>

| # | Time | On screen (action) | Cursor | Camera (target, zoom) | Hold |
| 1 | 0.0 | opening state | rests near first target | wide on <area>, 1.2x | 1.0 s |
| 2 | ... | ... | glide to <x>, press | ease to <target>, <zoom> | ... |
| n | end | final state | rests aside | pull back to the opening framing | 1.0 s |

Readability check: <which text must be read, its font px, the zoom that makes it 14 px on the display>
```

## Review checklist before committing a clip

Watch the clip at its real display size, then frame by frame at full size.

- The extension's icon, name and version on screen match the default branch; no old names anywhere.
- No live site content, no personal data, no real keys, no browser warnings or "controlled by automated software" bars.
- The cursor is visible the whole time, moves smoothly, and every click shows a press and a ripple.
- The camera never sits at 1.0x mid-clip, never fills the frame with a tiny control, and every move is eased.
- Every piece of text the clip relies on is readable at the display size.
- The camera is still at every click, and every result appears on camera.
- No shake on slow pans (step through a pan frame by frame).
- The loop seam is invisible; the poster is a meaningful frame.
- Phone cut: the action stays inside the portrait frame and the text is readable at 390 px wide.
- Sizes: each file under about 1.5 MB; silent (no audio track).
- The take, `events.json` and `camera.json` are kept with the run notes, so a re-render does not need a re-take.

## Usage: what each clip cost

demo-kit appends every `record` and `render` to `usage.jsonl` (wall time, frames, clip length, sizes); `demo-kit usage` prints the table.
AI tokens are not visible to the CLI, so the orchestrating agent adds them: when a recording subagent finishes, take the totals from its completion (tokens, tool uses, duration) and run `demo-kit usage note <take> --tokens "<totals>"`; when you recorded the take yourself, note what you can see, or "not visible".
Commit `usage.jsonl` with the clip's pull request in demo-kit.
This is to know what a clip costs, not to optimise it.

## Lessons

- **2026-11-09, building demo-kit on its test page.**
  The screencast is 2560x1600 only with both `deviceScaleFactor: 2` and `--force-device-scale-factor=2`; with one alone the frames are 1280 wide or the page reports devicePixelRatio 1.
  Headless extension loading needs Playwright's full Chromium (`channel: 'chromium'`), not the headless shell.
  A per-word hold must not override a storyboard's explicit hold, and a shot's own press must win over the previous hold, or the camera reaches a button after it was pressed.
  Fitting text at exactly 2.0x cut every line of a 680 px column; the whole-line rule fixed it.
  The opening framing sliced the page header and the h1 at the top edge; edge snapping fixed it.
  `locator.boundingBox()` waits up to 30 s for a missing element, which stalled tracking a word after the reading ended; poll with a short timeout.

## Mistakes we made (2026-11-09), not to repeat

- **Outdated build recorded:** the old icon and old naming showed.
  The recorder loaded whatever sat in the local checkout (TL;DW from a `dist/` folder of a checkout 13 commits behind origin; TubeVault from a review branch), with no check against the default branch.
- **Zoomed far into tiny UI:** the camera fitted each logged box (a settings card, a profile chip) to the frame, so small boxes got the biggest zoom.
  Zoom must come from readability and context, with a cap for controls.
- **Started at 1.0x and returned there between every focus:** no base zoom, so the camera kept pulling all the way out and diving back in.
- **Text not readable:** the highlighted paragraph stayed at a zoom where it could not be read on the homepage card, and the player bar (in a corner, in a closed shadow root) was too small to see what was pressed.
- **No visible cursor or click:** a tab screencast never draws the OS cursor, and the extension recorder had no overlay, so presses happened by magic.
- **Live sites:** YouTube and a live n8builds.dev post were on camera, with consent banners, page changes and network timing making takes flaky.
- **Popup as a floating card:** the popup page was shown in a tab, centred on a blank background, which reads as neither the real popup nor a page.
- **Shaky pans:** ffmpeg `zoompan` rounds to whole pixels, so slow pans and zooms jitter.

## Sources

- demo-kit: https://github.com/n8watkins/demo-kit

- Playwright `Screencast` API (`start`, `showActions` with `cursor` and `style`): https://playwright.dev/docs/api/class-screencast
- playwright-recast cursor and click effects: https://thepatriczek.github.io/playwright-recast/docs/guides/click-effects-and-cursor
- pw-cursor-overlay: https://github.com/hjiangtest/pw-cursor-overlay, mouse-helper: https://github.com/cenfun/mouse-helper
- ghost-cursor: https://github.com/Xetera/ghost-cursor
- FFmpeg zoompan shake, ticket #4298: https://ffmpeg.org/pipermail/ffmpeg-trac/2025-March/072904.html
- Remotion `interpolate` and license: https://www.remotion.dev/docs/interpolate, https://github.com/remotion-dev/remotion/blob/main/LICENSE.md
- Cursorful auto-zoom: https://chromewebstore.google.com/detail/cursorful-screen-recorder/eihpmapodnppeemkhkbhikmggfojdkjd
- OpenScreen: https://github.com/siddharthvaddem/openscreen
- `chrome.action.openPopup()` without policy from Chrome 127: https://groups.google.com/a/chromium.org/g/chromium-extensions/c/JNBpvtT4gYI
