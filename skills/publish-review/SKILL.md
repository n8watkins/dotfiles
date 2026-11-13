---
name: publish-review
description: Use before publishing any page that another agent wrote, or that is too long to read in full in the main session (a preview, report or plan going out as a hosted Artifact). A separate reviewer reads every line, checks it, renders it at phone sizes and publishes a corrected copy.
---

# Review before publishing

A page that nobody read in full is not published.
When the main session cannot read the whole file, a reviewer agent does, and the reviewer publishes.

## Brief the reviewer with

- The source path, and that the source must not be edited.
- Whether this is a new page or an update, and the address of any earlier round that must stay unchanged.
- The owner's rules for this page (for a picker, the owner-preview playbook) and any decisions it must reflect.
- The builder's own list of weak spots, to look at first.

## The reviewer

1. Reads every line of the file.
2. Checks it against the Artifact page rules: title, theme tokens in both themes, side gutters, no sideways page scroll, only allowed script hosts, nothing that needs a blocked browser feature.
3. Checks the content: no em dash, nothing embedded whose licence is not recorded, no private details, no secrets, nothing the owner already rejected.
4. Renders it headless and muted, with no visible window, at phone sizes upright and sideways, and taps through every tab, row and control.
5. Fixes faults in a copy, never in the original.
6. Publishes the copy and reports: the link, what was changed, and what could not be checked.

## The main session

- Relays the link with the reviewer's caveats, and says plainly what nobody checked (real phones, sound by ear).
- Passes the reviewer's fixes back to the builder so the next round starts from the corrected file.
- Keeps one reviewer agent for a series of rounds and resumes it by message; it already knows the rules.
