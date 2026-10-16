# Privacy

Memory reads local files and local programs, and nothing else. It has no
network client of any kind: no HTTP, no socket, no daemon call, no telemetry,
no crash reporting, no update check. It reads what `screenctx status`,
`launchctl print`, `recall search --json` and `recall today --json` print, the
collector's launchd plist, and the tail of the collector's log file; it writes
nothing except one thought at a time, which it hands to `recall capture` for
the memory repository to store in its own format. It keeps no store, no cache,
no log and no history of its own. Its only persisted state is three values
in `UserDefaults`: the appearance choice, the poll interval, and the moment a
timed pause ends. Search results and the Today glance live in memory while the
panel is open and are gone when it closes. Copying a result puts a file path,
not a memory, on the clipboard.
