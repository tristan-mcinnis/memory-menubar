import Foundation

/// The launchd job that runs the collector, and the two commands that turn it
/// off and on.
///
/// Memory owns no collector of its own. `com.tristan.screenctx` is a
/// `LaunchAgent` in the user's own `gui/<uid>` domain with `RunAtLoad` and
/// `KeepAlive`, so "off" means booting the service out of the domain and "on"
/// means bootstrapping the same plist back in. Nothing here writes the plist:
/// the collector repository owns it, and Memory only reads it for the log path
/// and reports what it says.
public struct LaunchAgent: Equatable, Sendable {

    /// What `launchctl print` says about the job right now.
    public enum State: Equatable, Sendable {
        /// Bootstrapped and running: a `state = running` line.
        case running
        /// Bootstrapped but not running (waiting, spawn-scheduled, exited).
        case loaded(String)
        /// Not in the domain at all. This is what the pause switch produces.
        case notLoaded
        /// launchctl could not be asked, or said something we do not read.
        case unknown(String)

        /// Whether the collector is meant to be up. `loaded` counts: launchd
        /// holds the job and `KeepAlive` will bring it back.
        public var isBootstrapped: Bool {
            switch self {
            case .running, .loaded: return true
            case .notLoaded, .unknown: return false
            }
        }
    }

    public let label: String
    public let plistPath: String

    public init(
        label: String = "com.tristan.screenctx",
        plistPath: String = NSHomeDirectory() + "/Library/LaunchAgents/com.tristan.screenctx.plist"
    ) {
        self.label = label
        self.plistPath = plistPath
    }

    public static let screenctx = LaunchAgent()

    /// `gui/501/com.tristan.screenctx`, the service target every verb takes.
    public func serviceTarget(uid: uid_t = getuid()) -> String {
        "\(domainTarget(uid: uid))/\(label)"
    }

    public func domainTarget(uid: uid_t = getuid()) -> String {
        "gui/\(uid)"
    }

    // MARK: - Commands

    /// The argument array that reads the job's state.
    public func printArguments(uid: uid_t = getuid()) -> [String] {
        ["print", serviceTarget(uid: uid)]
    }

    /// The argument array that stops the collector. `bootout` removes the job
    /// from the domain, so `KeepAlive` does not restart it.
    public func bootoutArguments(uid: uid_t = getuid()) -> [String] {
        ["bootout", serviceTarget(uid: uid)]
    }

    /// The argument array that starts the collector again, from the same plist
    /// on disk. `bootstrap` takes the domain and the file, not the label.
    public func bootstrapArguments(uid: uid_t = getuid()) -> [String] {
        ["bootstrap", domainTarget(uid: uid), plistPath]
    }

    // MARK: - Parsing

    /// Read one `launchctl print` run.
    ///
    /// A job that is not in the domain exits non-zero and says so on stderr;
    /// that is the pause state, not an error, so it is read from the text
    /// rather than assumed from the exit code alone.
    public static func parseState(_ result: CommandResult) -> State {
        let text = result.stdout + result.stderr
        if text.contains("Could not find service") || text.contains("No such process") {
            return .notLoaded
        }
        for rawLine in result.stdout.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("state = ") else { continue }
            let value = String(line.dropFirst("state = ".count)).trimmingCharacters(in: .whitespaces)
            return value == "running" ? .running : .loaded(value)
        }
        if result.succeeded { return .loaded("bootstrapped") }
        return .unknown(
            text.split(separator: "\n").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? "launchctl print failed"
        )
    }

    /// Ask launchd. Blocking: call it off the main thread.
    public func readState(tools: ToolPaths = .installed, uid: uid_t = getuid()) -> State {
        let result = Subprocess.run(
            executable: tools.launchctl,
            arguments: printArguments(uid: uid),
            timeout: 15
        )
        return Self.parseState(result)
    }

    /// Turn the collector off or on and hand back what launchctl said. The
    /// caller reports a failure out loud; Memory never claims a state it did
    /// not get back from launchd.
    public func setBootstrapped(_ on: Bool, tools: ToolPaths = .installed, uid: uid_t = getuid()) -> CommandResult {
        Subprocess.run(
            executable: tools.launchctl,
            arguments: on ? bootstrapArguments(uid: uid) : bootoutArguments(uid: uid),
            timeout: 20
        )
    }

    // MARK: - The plist

    /// What the job's plist declares, read straight off disk. Memory shows
    /// these; it never edits them.
    public struct Definition: Equatable, Sendable {
        public var label: String?
        public var programArguments: [String]
        public var standardOutPath: String?
        public var standardErrorPath: String?
        public var runAtLoad: Bool
        public var keepAlive: Bool

        /// The one log file to open. Both streams point at the same file in the
        /// collector's plist; if they ever diverge, stderr is the log, because
        /// `screenctx collect` writes every line it has, including the Screen
        /// Recording verdict `CollectorLog` reads, to stderr and none to stdout.
        public var logPath: String? { standardErrorPath ?? standardOutPath }
    }

    /// Parse a launchd plist. Nil when the file is absent or not a plist
    /// dictionary, so a missing job reads as missing rather than as empty.
    public static func parseDefinition(_ data: Data) -> Definition? {
        guard
            let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let plist = object as? [String: Any]
        else { return nil }
        return Definition(
            label: plist["Label"] as? String,
            programArguments: plist["ProgramArguments"] as? [String] ?? [],
            standardOutPath: plist["StandardOutPath"] as? String,
            standardErrorPath: plist["StandardErrorPath"] as? String,
            runAtLoad: plist["RunAtLoad"] as? Bool ?? false,
            keepAlive: (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] != nil)
        )
    }

    /// Read the job's plist from disk.
    public func definition() -> Definition? {
        guard let data = FileManager.default.contents(atPath: plistPath) else { return nil }
        return Self.parseDefinition(data)
    }
}
