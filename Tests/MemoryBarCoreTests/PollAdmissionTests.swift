import XCTest
@testable import MemoryBarCore

/// The poll admission gate and the work it saves.
///
/// `PanelModel.poll` used to queue one snapshot read per timer tick, no matter
/// what was already running. `PollGate` makes polling single-flight with one
/// bounded catch-up. These tests pin the gate's semantics, then run a
/// deterministic, delayed-reader, simulated-clock benchmark that counts the
/// snapshot reads submitted over a slow-read window for the old unconditional
/// path and the new gated path.
///
/// The delayed reader is a simulated 35 s read, the derived bound of
/// launchctl's 15 s plus screenctx's 20 s subprocess timeouts; it is a
/// synthetic scenario, not a live measurement. The claim is only about work
/// submissions in this simulation: the gated path submits fewer snapshot reads
/// and keeps the outstanding queue bounded for the same number of fresh
/// snapshots. Neither path makes a read faster, and the runtime effect was not
/// measured.
final class PollAdmissionTests: XCTestCase {

    // MARK: - Gate semantics

    func testAnIdleGateAdmitsTheFirstRead() {
        var gate = PollGate()
        XCTAssertTrue(gate.requestRead())
        XCTAssertTrue(gate.isInFlight)
        XCTAssertFalse(gate.isPending)
    }

    func testASecondTickWhileInFlightIsCoalescedNotAdmitted() {
        var gate = PollGate()
        XCTAssertTrue(gate.requestRead())
        XCTAssertFalse(gate.requestRead())
        XCTAssertTrue(gate.isInFlight)
        XCTAssertTrue(gate.isPending)
    }

    func testManyTicksWhileInFlightCollapseToOnePending() {
        var gate = PollGate()
        XCTAssertTrue(gate.requestRead())
        XCTAssertFalse(gate.requestRead())
        XCTAssertFalse(gate.requestRead())
        XCTAssertFalse(gate.requestRead())
        XCTAssertTrue(gate.isInFlight)
        XCTAssertTrue(gate.isPending)
        XCTAssertTrue(gate.hasQueuedWork)
    }

    func testCompletingWhilePendingOffersExactlyOneBoundedCatchUp() {
        var gate = PollGate()
        XCTAssertTrue(gate.requestRead())   // R1 in flight
        XCTAssertFalse(gate.requestRead())  // tick coalesced → one pending
        XCTAssertTrue(gate.completeRead())  // R1 done → one catch-up owed
        XCTAssertFalse(gate.isInFlight)
        XCTAssertFalse(gate.isPending)
    }

    func testTheCatchUpIsAdmittedThenFurtherTicksCoalesceAgain() {
        var gate = PollGate()
        XCTAssertTrue(gate.requestRead())   // R1
        XCTAssertFalse(gate.requestRead())  // pending
        XCTAssertTrue(gate.completeRead())  // released, catch-up owed
        XCTAssertTrue(gate.requestRead())   // catch-up R2 admitted
        XCTAssertTrue(gate.isInFlight)
        XCTAssertFalse(gate.isPending)
        XCTAssertFalse(gate.requestRead())  // tick during R2 → coalesced
        XCTAssertTrue(gate.isPending)
    }

    func testCompletingWithNoPendingDoesNotOfferARedundantCatchUp() {
        var gate = PollGate()
        XCTAssertTrue(gate.requestRead())   // R1
        XCTAssertFalse(gate.completeRead()) // no pending → no catch-up
        XCTAssertFalse(gate.isInFlight)
        XCTAssertFalse(gate.hasQueuedWork)
    }

    func testRepeatedPollAfterACompletionThatChangesNothingStillClearsTheGate() {
        // A read may complete and apply an unchanged snapshot, so `apply`
        // early-returns; the gate must still clear, and the next poll admits.
        var gate = PollGate()
        XCTAssertTrue(gate.requestRead())
        XCTAssertFalse(gate.completeRead())
        XCTAssertFalse(gate.isInFlight, "an apply that changed nothing must not pin the gate")
        XCTAssertTrue(gate.requestRead(), "the following poll admits again")
    }

    func testCompletingAnIdleGateIsAGuardedNoOp() {
        var gate = PollGate()
        XCTAssertFalse(gate.completeRead())
        XCTAssertFalse(gate.hasQueuedWork)
    }

    // MARK: - Simulated-clock benchmark

    /// The open-panel poll interval, from `PanelModel.pollInterval`. Open is the
    /// case that can back up: 15 s is shorter than a slow read.
    private let openInterval: TimeInterval = 15
    /// The simulated slow read, 35 s: the derived bound of the source's
    /// launchctl 15 s plus screenctx 20 s subprocess timeouts. A synthetic
    /// scenario for the benchmark, not a measured read.
    private let slowRead: TimeInterval = 35
    /// The closed-panel interval, and the window the benchmark runs for.
    private let closedInterval: TimeInterval = 60
    private let window: TimeInterval = 180

    func testSlowReadNoLongerStacksWorkSubmissions() {
        let old = unconditionalSubmissions(interval: openInterval, readDelay: slowRead, window: window)
        let new = singleFlightSubmissions(interval: openInterval, readDelay: slowRead, window: window)

        // Same freshness: both land one snapshot every slowRead seconds, the
        // physical bound. The guard reduces work, not how often a fresh read lands.
        XCTAssertEqual(new.completions, old.completions)
        XCTAssertEqual(new.completions, 5)

        // The old path launched one read per tick, whether or not it was stale.
        XCTAssertEqual(old.submissions, 13)
        XCTAssertEqual(old.maxOutstanding, 8, "the old queue backlog grows unbounded")

        // The gated path launches far fewer, and is bounded to one in flight
        // plus one owed catch-up, so no backlog builds.
        XCTAssertEqual(new.submissions, 6)
        XCTAssertLessThan(new.submissions, old.submissions)
        XCTAssertLessThanOrEqual(new.maxOutstanding, 2)
        XCTAssertLessThan(new.maxOutstanding, old.maxOutstanding)
    }

    func testAHealthyReadKeepsItsCadenceAndIsNotThrottled() {
        // With the closed-panel cadence (60 s) and a read faster than the tick,
        // there is nothing to coalesce: the gate admits every idle tick and the
        // two paths agree exactly. This guards against over-throttling a load
        // that does not need throttling, and against dropping results.
        let old = unconditionalSubmissions(interval: closedInterval, readDelay: 30, window: window)
        let new = singleFlightSubmissions(interval: closedInterval, readDelay: 30, window: window)
        XCTAssertEqual(new.submissions, old.submissions)
        XCTAssertEqual(new.completions, old.completions)
        XCTAssertEqual(new.maxOutstanding, old.maxOutstanding)
    }

    // MARK: - Benchmark helpers

    private func tickCount(interval: TimeInterval, window: TimeInterval) -> Int {
        Int((window / interval).rounded(.down)) + 1
    }

    /// The old path: every tick unconditionally queues a snapshot read. Reads
    /// run one at a time on the serial work queue, each taking `readDelay`, so
    /// launch i, submitted at `i * interval`, finishes when the executor is next
    /// free: `max(submit, previousFinish) + readDelay`. The outstanding count is
    /// launched-not-yet-landed at the end of the window, which for a slow read
    /// is the growing backlog.
    private func unconditionalSubmissions(
        interval: TimeInterval,
        readDelay: TimeInterval,
        window: TimeInterval
    ) -> (submissions: Int, completions: Int, maxOutstanding: Int) {
        let launches = tickCount(interval: interval, window: window)
        var nextFree: TimeInterval = 0
        var completions = 0
        for i in 0..<launches {
            let submit = Double(i) * interval
            let start = max(submit, nextFree)
            let finish = start + readDelay
            nextFree = finish
            if finish <= window { completions += 1 }
        }
        return (launches, completions, launches - completions)
    }

    /// The new path: `PollGate` admits a read only when none is in flight,
    /// coalesces ticks into one pending catch-up, and runs at most one catch-up
    /// after a slow read. A read's completion is processed at its true finish
    /// time (not at the next tick), so a catch-up starts the moment the previous
    /// read lands. When a completion and a tick land at the same moment, the
    /// completion is processed first.
    private func singleFlightSubmissions(
        interval: TimeInterval,
        readDelay: TimeInterval,
        window: TimeInterval
    ) -> (submissions: Int, completions: Int, maxOutstanding: Int) {
        var gate = PollGate()
        var submissions = 0
        var completions = 0
        var runningUntil: TimeInterval? = nil
        var maxOutstanding = 0
        var nextTick: TimeInterval = 0

        func outstanding() -> Int {
            (runningUntil == nil ? 0 : 1) + (gate.isPending ? 1 : 0)
        }

        while nextTick <= window || (runningUntil.map { $0 <= window } ?? false) {
            let tickDue = nextTick <= window ? nextTick : .infinity
            let completionDue = runningUntil ?? .infinity

            if completionDue <= tickDue {
                let catchUp = gate.completeRead()
                completions += 1
                runningUntil = nil
                if catchUp {
                    _ = gate.requestRead()
                    runningUntil = completionDue + readDelay
                    submissions += 1
                }
            } else {
                let tick = nextTick
                nextTick += interval
                if gate.requestRead() {
                    submissions += 1
                    runningUntil = tick + readDelay
                }
            }
            maxOutstanding = max(maxOutstanding, outstanding())
        }
        return (submissions, completions, maxOutstanding)
    }
}
