import Foundation

/// One reading of the collector, merged from the three things Memory can ask:
/// what `screenctx status` printed, what launchd says about the job, and what
/// the collector wrote in its own log about its Screen Recording and
/// Accessibility grants.
///
/// This is the only place those three are turned into a word and a colour, so
/// the menu bar icon, the panel header, and the settings pane can never
/// disagree with each other.
public struct CollectorSnapshot: Equatable, Sendable {

    /// What the dot means. Never the only carrier: every case pairs with a
    /// word in `headline`, per DESIGN.md's accessibility rule.
    public enum Health: Equatable, Sendable {
        /// Ticks are landing. Green.
        case collecting
        /// The job was booted out of the launchd domain, which is what the
        /// panel's master switch and "Pause for 1 hour" do. Red.
        case paused
        /// A permission the collector needs is not granted. Red.
        case permission
        /// Bootstrapped but no recent tick, or no store yet. Red.
        case stopped
        /// Nothing has been read yet, or the collector is not installed. Dim.
        case unknown
    }

    public var health: Health
    /// The status line beside the dot: a state word and the one fact that fits
    /// next to it in a 300 px panel. Measured against the rendered panel, not
    /// guessed: three parts truncate, two do not.
    public var headline: String
    /// The rest, on its own dim line under the header: how big the store is,
    /// when the last tick landed, and what was in front. Nil when there is
    /// nothing to add.
    public var context: String?
    /// Whether launchd currently holds the job. The panel's master switch
    /// reflects this, not a preference of Memory's own.
    public var isBootstrapped: Bool
    /// The database file screenctx named, when it named one. "Open store
    /// folder" reveals its directory, so Memory never hard-codes the path it
    /// can be told.
    public var storePath: String?

    public init(
        health: Health,
        headline: String,
        context: String? = nil,
        isBootstrapped: Bool,
        storePath: String? = nil
    ) {
        self.health = health
        self.headline = headline
        self.context = context
        self.isBootstrapped = isBootstrapped
        self.storePath = storePath
    }

    /// The directory holding the store, for a reveal in Finder.
    public var storeFolder: String? {
        storePath.map { ($0 as NSString).deletingLastPathComponent }
    }

    /// Nothing read yet. What the panel shows for the first fraction of a
    /// second after it opens, and whenever a poll has not landed.
    public static let pending = CollectorSnapshot(
        health: .unknown, headline: "Checking…", isBootstrapped: true
    )

    /// Merge one poll.
    ///
    /// Order of precedence, and why:
    ///
    /// 1. **Not installed** beats everything. There is nothing to say about a
    ///    collector that is not on disk.
    /// 2. **Paused** beats a permission problem. Being booted out is a thing
    ///    the user just did on purpose, and it is the fact that explains why
    ///    nothing is being collected; a missing grant is still true, and still
    ///    shows the moment the collector is switched back on.
    /// 3. **Permissions** beat the tick state, because a denied grant is the
    ///    cause and "Stopped" would only be the symptom. Both grants come from
    ///    the collector's log (`CollectorLog`), never from the `accessibility:`
    ///    line of `screenctx status`: Memory runs that status, so TCC answers
    ///    that line for Memory.app, not for the collector.
    /// 4. Otherwise the collector's own status word carries.
    public static func merge(
        status: ScreenctxStatus?,
        launchState: LaunchAgent.State,
        screenRecording: CollectorLog.ScreenRecording,
        accessibility: CollectorLog.Accessibility = .unknown,
        collectorInstalled: Bool = true
    ) -> CollectorSnapshot {
        let bootstrapped = launchState.isBootstrapped

        guard collectorInstalled else {
            return CollectorSnapshot(
                health: .unknown,
                headline: "Collector not installed",
                context: "screenctx is not on this Mac",
                isBootstrapped: false
            )
        }

        if case .notLoaded = launchState {
            return CollectorSnapshot(
                health: .paused,
                headline: "Paused",
                context: "collector job is not loaded",
                isBootstrapped: false
            )
        }

        if accessibility == .missing {
            return CollectorSnapshot(
                health: .permission,
                headline: "Accessibility missing",
                context: "grant it in System Settings › Privacy & Security",
                isBootstrapped: bootstrapped,
                storePath: status?.storePath
            )
        }

        if screenRecording == .missing {
            return CollectorSnapshot(
                health: .permission,
                headline: "Screen Recording missing",
                context: "text capture continues; frames and OCR wait",
                isBootstrapped: bootstrapped,
                storePath: status?.storePath
            )
        }

        guard let status else {
            return CollectorSnapshot(
                health: .unknown, headline: "Checking…", isBootstrapped: bootstrapped
            )
        }

        // The state word plus the one fact that fits beside it. Everything
        // else drops to the line below. Every part is screenctx's own string,
        // never re-spelled here.
        let headline = ([status.state == .unknown ? status.statusLine : status.state.rawValue]
            + [status.framesText].compactMap { $0 })
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let context = [status.sizeText, status.tickText, status.frontApp]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        let health: Health
        switch status.state {
        case .collecting: health = .collecting
        case .stopped: health = .stopped
        case .noStore: health = .unknown
        case .unknown: health = .unknown
        }

        return CollectorSnapshot(
            health: health,
            headline: headline.isEmpty ? "Unknown" : headline,
            context: context.isEmpty ? nil : context,
            isBootstrapped: bootstrapped,
            storePath: status.storePath
        )
    }

    /// Read every source once and merge. Blocking on three subprocesses and a
    /// file read: call it off the main thread.
    public static func read(
        agent: LaunchAgent = .screenctx,
        tools: ToolPaths = .installed
    ) -> CollectorSnapshot {
        let installed = tools.exists(tools.screenctx)
        let launchState = agent.readState(tools: tools)
        // A job that is booted out has nothing to report and its status would
        // only be stale; skip the two reads that cost a subprocess and a file.
        guard installed, launchState.isBootstrapped else {
            return merge(
                status: nil,
                launchState: launchState,
                screenRecording: .unknown,
                accessibility: .unknown,
                collectorInstalled: installed
            )
        }
        let log = CollectorLog.verdicts(logPath: agent.definition()?.logPath)
        return merge(
            status: ScreenctxStatus.read(tools: tools),
            launchState: launchState,
            screenRecording: log.screenRecording,
            accessibility: log.accessibility,
            collectorInstalled: true
        )
    }
}
