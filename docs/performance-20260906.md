# Poll admission: simulation record

Date: 2026-09-06

## Change

`PanelModel.poll` queued a snapshot read on every timer tick, whether or not the
previous read had finished. The work queue is serial, so completion order was
already correct and `apply` discarded duplicates; the cost was redundant
subprocess spawns. Polling is now single-flight through `PollGate` in
`MemoryBarCore`, scoped to `poll` only.

## Simulation metrics

Deterministic simulated-clock benchmark in `PollAdmissionTests`, delayed reader
of 35 s (the derived bound of launchctl's 15 s plus screenctx's 20 s subprocess
timeouts), 15 s open-panel tick, 180 s window.

| Path | Snapshot reads submitted | Fresh snapshots landed | Peak outstanding |
| --- | --- | --- | --- |
| Old (one read per tick) | 13 | 5 | 8 |
| New (single-flight gate) | 6 | 5 | 2 |

Same freshness (one landing per slow-read period, the physical bound). The gate
reduces work submissions and keeps the outstanding queue bounded.

## What this is not

No real CPU gain. The gate does not make a read faster. It stops stale reads
from being launched behind a slow one. The runtime effect was not measured; the
numbers above come from the simulation only.

## Validation gap

The core admission state (`PollGate`) and the simulation are covered by the core
test target. `PanelModel` is AppKit and is not integration-tested; its wiring to
the gate was reviewed statically, per this repo's existing convention that tests
live only on the core.
