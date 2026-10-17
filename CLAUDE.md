# memory-menubar: agent notes

`AGENTS.md` is a symlink to this file. One way of doing each thing; when a
change would create a second way, change the first one instead.

Memory is the menu-bar face of the memory layer. It owns no store, no
collector, and no data. Every fact it shows came out of `screenctx status`,
`launchctl print`, the collector's log, or `recall … --json`, and every action
is a call to one of those programs. If a feature would need Memory to keep its
own copy of something, the feature is wrong.

Two targets. `MemoryBarCore` is pure: parsing, merging, and the launchctl
argument arrays, with no AppKit, no window, and no timer. `MemoryBar` is the
app: the view layer, the polling, and the status item. Tests live only on the
core, against captured output in `Tests/MemoryBarCoreTests/Fixtures/`.

## What must never break

- **No shell interpolation.** `Subprocess.run` is the only place a `Process`
  is built, it takes an executable path and an argument array, and there is no
  second copy of it. A captured thought with a quote or a semicolon in it is
  one argument, never syntax.
- **Nothing blocks the main thread.** Every subprocess runs on one of the
  model's two serial work queues (the collector's poll and switch on one, the
  recall verbs on the other, so a key never waits behind a collector read)
  and comes back through `DispatchQueue.main`. A wedged CLI is
  bounded by `Subprocess.run`'s timeout, not by the panel freezing.
- **No window without being asked.** `install.sh` does not launch,
  `--render-proof` and `--doctor` set `.prohibited` and exit, and the only
  code that takes the foreground is behind a row the user picked.
- **An install never destroys the working app.** `install.sh` verifies the
  candidate (codesign, plist id, executable, icon, LSUIElement, and the embedded
  codesign Identifier) before touching the destination, renames the previous
  app aside instead of deleting it first, keeps an immutable snapshot with its
  hash and signing provenance outside Git, and restores it if publish or
  post-verify fails. `--rollback` restores the last snapshot. A properly-signed
  installed app is never silently replaced with a different signing identity
  (ad-hoc, another team, or a different identifier): that install is refused and
  only `--allow-signing-change` overrides on purpose. A held install lock is
  refused, never stolen. Exit 3 means the app was installed but the login item
  was not registered, and no rollback was done. Install never quits or
  relaunches a running instance on its own.
- **Say unknown when it is unknown.** A missing collector, an unreadable
  `today` section, a partial task read, and a launchctl answer we do not
  recognise are all shown as themselves. Never draw an unreadable thing as an
  empty one, keep recall's own reason for a section that did not come back
  whole, and never show a count Memory did not get back.
- **Never re-spell a CLI's words.** The frame count, the size, the tick age
  and the front app are carried as the strings screenctx chose; a capture
  confirmation is the sentence recall printed after its dot. Memory decides
  which parts fit in 300 px, not what they say.

## Conventions

- House design through the design-system package (`HouseDesign` tokens,
  `HouseUIKit` Slate menu-bar kit), pinned in `Package.swift` by GitHub URL and
  tag. Never retype a value. A fix lands in design-system and is released as a
  tag; raise the `from:` pin here to take it.
  Memory's own panel code is `MenuBarPanelView.swift` and
  `MenuBarPanelController.swift`.
- Both grants, Screen Recording and Accessibility, are read from the
  collector's log (`CollectorLog.verdicts`), never probed here.
  `CGPreflightScreenCaptureAccess` answers for the calling process, so Memory
  asking would report Memory's grant and say nothing true about screenctx.
  The `accessibility:` line of `screenctx status` is the same trap: Memory
  runs that status, so TCC answers it for Memory.app. It is parsed and never
  trusted; the collector's own `waiting for Accessibility permission` lines,
  against its later Screen Recording and `collecting every` lines, are the
  answer.
- `CollectorSnapshot.merge` is the only place three sources become one word
  and one colour. The precedence (not installed, then paused, then
  permissions, then the tick state) is documented there and pinned by tests;
  change the order there, not in a view.
- Fixtures are captured from real runs. The three `screenctx status` variants
  that cannot be produced on a live Mac (stopped, no store, no ticks) are
  written to screenctx's own printing rules and say so. `recall-today-v2.json`
  is the previous `today` payload kept as a fixture: it is what the version
  gate must refuse, and it is real output rather than a made-up body.
- The panel width, the eight-content-row Today budget (section labels are
  excluded), the six-result search cap, the 250 ms debounce and the idle
  backoff (`idleThreshold`, `idlePollCeiling`, `pollToleranceFraction`) are
  constants on `PanelModel`, not numbers in a view. The health lines, the
  captures and the three curated task sections all spend that one content-row
  budget, and `makeTodayPlan` is the single place the split
  happens. `todayTaskGroups`, `makeTodayPlan`, `todayBacklogNote`,
  `todayTriageNote`, `todayTaskStatusNote`, `clippedReason`, `shortDay`,
  `taskAction` and `taskRequest` are pure, so the layout, the wording and the
  version of a reason line that fits are tested without a window.
- Today says what the whole board is doing, not just the day. The backlog line
  names `open_count` and the two biggest `lane_counts`, so an empty day cannot
  read as an empty board; a board that could not be read draws no count at all,
  and no sections, because three empty sections over a failed read is the lie
  the note exists to stop. A section that had rows but no budget says
  `N more` through `TodayTaskGroup.placeholder`, never its empty line.
- Capture rows are `PanelStaticRow` and carry no button, no hover and no
  selection: a capture is read, not actioned. Task rows are selectable in Today
  mode, and Return runs `runTaskAction`: it opens the owning `00-tasks.md`
  through `NSWorkspace` when the source is a file a person can act in, and
  otherwise copies `taskRequest`'s paste-ready sentence to the clipboard.
  Memory writes no task store and owns no task writer.
- The full backlog is reachable two existing ways and neither is drivable from
  this panel: `memory.tasks` ("Open Tasks") in the house command manifest, run
  by Quick Launch's catalog, and `recall tasks` in a shell. Quick Launch has no
  URL scheme and no socket, so the panel shows the backlog count and offers no
  row for it rather than a fake action.
- Polling costs nothing while nobody looks. Every repeating timer carries a
  tolerance, so macOS batches its wakeup. A panel unopened for `idleThreshold`
  polls at a longer interval, doubling per further threshold up to
  `idlePollCeiling` and never below the user's configured interval; opening it
  restores the configured cadence at once, and an open on words older than one
  interval starts a read behind the panel so the tick age on screen is never
  older than it says. `backedOffInterval` and `isStale` are pure, and the clock
  is injected (`now`), so the decision is tested without waiting. Usage and
  Local Models carry the same constants and the same rule.
- The poll is single-flight through `PollGate` in `MemoryBarCore`: one snapshot
  read in flight and one owed catch-up, so a slow read never stacks stale reads
  behind it on the serial work queue. It guards `poll` only; `setCollecting`'s
  authoritative re-read queues its own work and bypasses it.
- The house command contract (`../design-system/docs/app-commands.md`) is
  published by `CommandManifest` at launch: a manifest at `~/Library/
  Application Support/House/commands/memory.json` on the `exec` transport,
  whose endpoint is the resolved `recall` path, plus a status document beside
  it rewritten from the snapshot the panel already polls. Memory publishes the
  four capture-and-read verbs only (`memory.capture` "Capture a Thought",
  `memory.search`, `memory.today`, `memory.tasks`); nothing that edits or
  deletes a memory is drivable from outside. The capture command runs
  `recall capture`, never the hidden `remember` alias: "remember" belongs to
  ledger and `memory-remember.py` in the house glossary. Its id was
  `memory.remember` until 2026-09-26; no Quick Launch alias, hotkey or usage
  record on this Mac referred to the old id when it moved. A manifest that cannot be written is one `NSLog` line
  and nothing else. A new command lands in `CommandManifest.commands` in the
  same commit that adds it.
- Verify with the render proof and `--doctor`, never by launching the app. A
  claim about how a surface looks is backed by a PNG somebody looked at.

## Related repositories

- `../design-system`: the rule (`DESIGN.md`), the token generator, and the
  package this repo pins. Its `check-consumers` verifies the pin.
- `../memory-screenctx`: the collector and its launchd agent. Memory reads its
  status and drives its job; it never edits its plist or its store.
- `../memory-recall`: the CLI behind Capture, Search and Today. Memory reads
  its `--json` contract: `search` at `schema_version` 1 and `today` at
  `schema_version` 3 (captures, the unresolved-triage summary, the three
  exclusive task sections, and the full board's `open_count` and
  `lane_counts`). Both are read at exactly that version: `RecallOutput.decode`
  refuses any other version from the envelope, before the body is decoded, so
  a moved contract is one plain sentence rather than truncated JSON. The text
  output is the human contract and Memory does not parse it.
- `../cotype`: the first Slate menu-bar app, and the origin of the component
  kit and the panel plumbing here.

## Voice

One declarative sentence first. Mechanism, not benefit-speak. No marketing
adjectives, no em dashes. State limits early.
