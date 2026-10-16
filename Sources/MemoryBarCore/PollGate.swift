import Foundation

/// Single-flight admission for the collector poll.
///
/// `PanelModel.poll` queued a snapshot read on every tick whether or not the
/// previous had finished. The open-panel tick is 15 s and a read is bounded by
/// launchctl's 15 s plus screenctx's 20 s subprocess timeouts, so a slow read
/// (~35 s in the simulated benchmark here) outlives the tick and stale reads
/// stack up behind it. The serial queue already orders their completions and
/// `apply` dedupes, so the cost was redundant subprocess spawns, not order.
/// This gate bounds that: one read in flight, one owed catch-up, a tick while
/// running is coalesced not queued. It guards `poll` only; `setCollecting`'s
/// authoritative re-read queues its own work and bypasses it.
public struct PollGate: Equatable, Sendable {

    /// A read has been admitted and has not yet completed.
    public private(set) var isInFlight = false
    /// One tick arrived while a read was in flight, so one catch-up is owed.
    public private(set) var isPending = false

    public init() {}

    /// Called on each poll tick. Returns true when a read should be admitted
    /// (queued) now. When a read is already in flight, the tick is coalesced
    /// into the single pending catch-up and no read is admitted, so the queue
    /// stays bounded to one in flight and one owed.
    @discardableResult
    public mutating func requestRead() -> Bool {
        if isInFlight {
            isPending = true
            return false
        }
        isInFlight = true
        isPending = false
        return true
    }

    /// Called when the admitted read has finished and applied. Returns true
    /// when one bounded catch-up read should be admitted immediately. The gate
    /// is released by the call, so it clears even when the caller applied an
    /// unchanged snapshot and early-returned; a caller that gets true queues
    /// one fresh read with `requestRead`, which admits it.
    @discardableResult
    public mutating func completeRead() -> Bool {
        guard isInFlight else { return false }
        isInFlight = false
        let catchUp = isPending
        isPending = false
        return catchUp
    }

    /// True while there is read work admitted or owed. Bounded to two by the
    /// single-flight rules above.
    public var hasQueuedWork: Bool { isInFlight || isPending }
}
