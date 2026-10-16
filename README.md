# Memory

The menu-bar face of the memory layer on this Mac. One bookmark in the status
bar: is the screen-context collector running, capture a thought, find one, and
see what today looks like, without opening a window.

Memory owns nothing. Everything it shows or does is a call to a program that
already exists here:

| Row | What it runs |
| --- | --- |
| The header status line | `screenctx status`, `launchctl print`, and the collector's own log (both permission verdicts) |
| The header switch | `launchctl bootstrap` / `launchctl bootout` on `com.tristan.screenctx` |
| Capture a thought (⌘N) | `recall capture <text>` |
| Search memory (⌘F) | `recall search <query> --json`, debounced 250 ms |
| Today (⌘T) | `recall today --json` |
| Pause collector for 1 hour | `launchctl bootout`, with a deadline on disk that brings it back |
| Screen-context store | reveals the store screenctx named, in Finder |
| Collector log | opens the log path the launchd plist declares |

There is no "Open screen timeline" row. screenctx is the one screen-history
collector on this Mac, the one Memory switches on and off, and its timeline
is read in a shell with `screenctx timeline` and `screenctx search <query>`;
the panel has no view of it. Quick Launch's old Screen History collector (a
separate one, opt-in and locked off) was retired by decision on 2026-09-26;
Memory never read or controlled it.

## The panel

300 px of glass in place of an NSMenu, following the "Menu bar panel"
component in `../design-system/DESIGN.md`. A 26 px icon tile, the app name, a
status line with a 6 px dot, and the collector's master switch. Then three
action rows with outlined key caps, a divider, three rarer rows, and a footer
well with Settings ⌘, and Quit ⌘Q.

Arrows move the selection, Return runs it, Escape backs out one step and then
closes. Capture and Search replace the rows with a field in place; Today
replaces them with the glance. The panel closes when it loses focus.

Today budgets eight content rows, excluding the small section labels. Health
lines reserve their places before capture and task rows are allocated: the
unresolved triage queue (`1 unresolved capture · oldest 2026-09-02`), a partial
task read's own reason, and the whole open backlog
(`42 open in the backlog · requires_action 17 · captured 9`). The panel draws
today's captures first, then those health lines, then the three curated task
sections `recall today` returns: due today, overdue, and in progress. Every
non-empty section gets a row before any
section spends the leftover, so a long due-today list cannot hide the overdue
one; a section that did not fit says how many more there are rather than
`nothing`. The backlog line is why an empty day cannot read as an empty board:
a day with nothing due still says how many tasks are open behind it. A long
partial-read reason is clipped at 140 characters, keeping its head; the whole
reason is in `recall today`. A section that could not be read at all says so in
the danger colour rather than looking empty.

Capture rows are text, not controls: a capture is something to read. Task rows
are selectable. Arrows move through them and Return opens the owning source
file when it is the project's `00-tasks.md` (the same native open the Collector
log row uses); for a store record such as `tasks.jsonl`, where opening is a
dead end, Return copies a paste-ready request instead, naming the task, its
file, its lane, its project and its id.

The full backlog is a Quick Launch gesture, not a panel row. Memory publishes
`memory.tasks` ("Open Tasks") through the house command contract, so Quick
Launch's catalog can run `recall tasks`, and `recall tasks` in a shell prints
the same list. Memory does not offer a row for it: Quick Launch has no URL
scheme and no socket, so there is nothing the panel could open without
inventing a route, and the panel shows the backlog count instead of a row that
does nothing.

The status dot is the only colour: green while ticks are landing, red when the
collector is paused, stopped, or missing a permission, dim when nothing has
been read yet. The word beside it always says the same thing, so the colour is
never the only carrier.

## Status item

The same bookmark the app icon draws, as a template image, so the icon and the
status item read as one app. `bookmark.slash` while paused. `bookmark` painted
in `danger` when a permission the collector needs is missing.

## Build and install

```
swift build && swift test          # the parsers, against captured CLI output
sh scripts/scrub.sh               # publish gate, prints SCRUB_CLEAN
bash scripts/test-install.sh      # installer suite, 87 assertions
./scripts/build-app.sh             # dist/Memory.app, signed
./scripts/install.sh --no-launch   # into /Applications, login item, no launch
```

`install.sh` does not launch the app: it puts an item in the menu bar and a
launch steals focus. Pass `--launch` when you want it opened.

Every install verifies the candidate (codesign, plist id, executable, icon,
LSUIElement) before touching the installed app, renaming the previous app
aside rather than deleting it and keeping an immutable snapshot (with its hash
and signing provenance) so a bad build can be taken back:

```
./scripts/install.sh --no-build --rollback   # back to the last good build
./scripts/install.sh --list-backups          # what snapshots are kept
```

A properly-signed installed app is never silently replaced with a different
signing identity. That install is refused and the destination is left
untouched; pass `--allow-signing-change` only to override deliberately.

Exit codes: `0` installed, `1` failed (nothing changed, or the prior app was
restored), `3` the app was installed but the login item could NOT be registered
(no rollback happened; fix the login item and re-run).

If another install holds the lock, or a stale lock is left behind, `install.sh`
refuses instead of stealing it: clear a stale lock with `rm -rf <lock dir>` and
retry.

Backup snapshots are never auto-pruned; the disk cost grows with the number of
installs. Move or clear the backup root yourself if you want them gone.

Two diagnostics, neither of which puts a window on screen:

```
memory-bar --doctor                # every read the panel makes, printed
memory-bar --render-proof <dir>    # every Slate surface, as PNGs
```

## Requirements

- macOS 14 or later, Apple Silicon.
- `screenctx` at `~/.local/bin/screenctx` with its launchd agent
  `com.tristan.screenctx` (the memory-screenctx repository installs both).
- `recall` at `~/.local/bin/recall`, built from memory-recall at a version
  that has `--json` on `search` and `today`, with `today` at `schema_version` 3
  (2026-09-17 or later). Version 3 adds the full open-backlog `open_count` and
  `lane_counts` and the `triage` summary. Memory reads `today` at exactly 3 and
  `search` at exactly 1; a payload at any other version is refused with one
  sentence naming both, never drawn from a shape that moved.

Memory says so plainly when either is missing rather than showing an empty
panel: run `memory-bar --doctor` to see which.

## Design

The look is the house system: `../design-system/DESIGN.md` is the rule,
`Sources/MemoryBar/HouseDesign.swift` is a verbatim copy of the generated
token file, and `make check-consumers` in that repository fails if this copy
drifts. `Sources/MemoryBar/HouseUI.swift` and `MenuBarPanel.swift` are the Slate
menu-bar kit, byte copies of `design-system/kit/` (`make sync-kit` there), so
the menu bars are one look.

## License

All rights reserved. One Mac, one user.
