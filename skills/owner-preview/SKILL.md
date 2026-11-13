---
name: owner-preview
description: Use before building any page the owner will try in order to choose between options (emotes, sounds, skins, rooms, colours, layouts), and before any taste-driven or sweeping UI change. Covers how the preview must be delivered (hosted, for a phone), the picker layout, what makes candidates good, sound, and the round-by-round process.
---

# Previews the owner picks from

The owner's order is words, then pictures, then a build.
A tappable page of candidates gets clear decisions in minutes; building the full feature first throws most of the work away.
Build what does not depend on taste underneath (rules, limits, tests) and hold everything that is taste until the owner has picked.

## Delivery

- The owner reviews on a phone.
  Local and LAN addresses do not open there.
- Deliver a hosted Artifact, or put the preview on the live site at an unlisted address or behind a switch.
  A localhost link is only for when the owner says they are at the PC.
- An Artifact is one self-contained file within the page rules and size limit: assets embedded, scripts only from the allowed CDNs.
- Each round gets a new address; earlier rounds stay published unchanged.
- Small, clear fixes skip the preview.

## Picker layout

1. The thing being changed (the stage) stays fixed in view.
2. Options are a list in their own scrolling panel: beside the stage on a sideways phone, under it on an upright one.
3. Tapping an option plays it at once, and the page itself never scrolls.
4. Every control for an option sits on that option's own row: its star and its alternates (take A, B, C, none).
5. Choosing a new option stops the previous one immediately, sound included.
6. A star on each option and a picks summary the owner can copy.
7. Show each option at the size it will really be seen, not only large.
8. Put recommendations on the page, next to the choice they are about, in plain words.

## Candidates

- Cut anything that does not read at real size before the owner sees it, and say what was cut and why.
- Prefer one clear prop and one simple motion, readable in half a second from across the room.
- Never make another person's character look harmed or changed; it reads as a game event, not a joke.
- Do not lean on a specific existing meme, character, brand or performer.
- When the owner corrects a direction, apply the correction to every candidate it covers, not only the one named.

## Sound

- An agent cannot hear.
  It can check length, loudness, clean starts and clipping; say that, and let the owner choose by ear.
- Use real recordings, public domain (CC0) only when the repository is public.
  Read the licence on each recording's own page and record title, author, address, licence and date in a credits file.
- Offer two or three labelled takes per slot.
- Commit no media until the owner has picked.

## Process

- Expect several rounds and make each one cheap: generate the page from sources with a script.
- Check the layout headless at real phone sizes, upright and sideways, small phones included (667 by 375 and 568 by 320 have both broken pages before).
- Hunt for bugs without waiting to be told: spam taps, interrupt things halfway, rotate.
- Whatever the preview draws should be data the real product can reuse, so the picks carry into the build.
- Before publishing, follow the publish-review playbook.
- After the last round, write what was learned and what was decided into the project's status or lessons document.
