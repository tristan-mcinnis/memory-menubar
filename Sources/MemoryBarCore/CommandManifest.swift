import Foundation

/// What Memory tells the rest of the house it can do.
///
/// The house command contract (`design-system/docs/app-commands.md`): every
/// app writes one manifest at `~/Library/Application Support/House/commands/
/// <app-id>.json`, and Quick Launch reads all of them. Memory speaks the
/// `exec` transport, because the work is already done by the `recall` CLI and
/// a second lane into the same store would be a second way of doing one thing.
///
/// Nothing here destroys or rewrites a memory. `recall capture`, `recall
/// search`, `recall today` and `recall tasks` capture and read; the verbs that
/// edit or delete stay in the memory repository and in Memory's own panel, per
/// the contract's rule that no command may destroy data from outside the
/// owning app.
///
/// Pure: this type builds documents and resolves paths. The app writes them.
public enum CommandManifest {

    /// The app id, which is also the manifest's file name.
    public static let appID = "memory"
    public static let appName = "Memory"
    public static let schema = 1
    public static let transport = "exec"

    // MARK: - The documents

    /// One row in Quick Launch's catalog.
    public struct Command: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        /// The first argument handed to the endpoint executable.
        public let verb: String
        /// `null`, `"text"`, or `"choice"`: what the caller must collect
        /// before running the row.
        public let needs: String?

        public init(id: String, title: String, verb: String, needs: String?) {
            self.id = id
            self.title = title
            self.verb = verb
            self.needs = needs
        }

        // `needs` is written even when it is nil. The contract's readers
        // switch on the key, so an omitted key would read as a missing field
        // rather than as "takes no argument".
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(verb, forKey: .verb)
            try container.encode(needs, forKey: .needs)
        }
    }

    public struct Document: Codable, Equatable, Sendable {
        public let schema: Int
        public let app: String
        public let name: String
        public let transport: String
        /// The `recall` executable, resolved on this Mac.
        public let endpoint: String
        /// Where the status document is, for the `exec` transport.
        public let status: String
        public let commands: [Command]
    }

    /// The answer the contract requires of every app.
    ///
    /// `exec` has no live channel: `recall` is a stateless CLI and cannot
    /// answer for the app, and making it try would cost a subprocess per call
    /// and invent a second source of truth about the collector. So Memory
    /// publishes this document as a file beside the manifest, rewritten from
    /// the snapshot the panel already polls and only when that snapshot
    /// changes. A missing or malformed file means unavailable, as a dead
    /// socket does. Age means nothing: Memory's state rarely changes, so an
    /// old file is a healthy app, and the document stands until the app
    /// rewrites it. Nothing here or in Quick Launch expires it.
    public struct Status: Codable, Equatable, Sendable {
        public let app: String
        /// Whether the commands in the manifest can run at all, which for an
        /// `exec` app is whether its endpoint is still on disk.
        public let ok: Bool
        /// Always false. Every command returns as soon as `recall` does;
        /// Memory runs nothing long enough for a caller to wait on.
        public let busy: Bool
        /// One short human phrase, shown verbatim. It is the same headline the
        /// panel and the menu bar glyph carry, never a second wording.
        public let detail: String
    }

    /// The four verbs. The panel's three rows come first, in their order;
    /// `tasks` is the read-only open-task list, appended last.
    ///
    /// `doctor` is deliberately absent. It prints Memory's own wiring (paths,
    /// the capture route, the store size) for a person reading a terminal, it
    /// changes nothing, and a launcher row for it would hand back a block of
    /// key and value lines with nothing to act on. The facts it prints are in
    /// the panel already, and `recall doctor` is one word away in a shell.
    public static let commands: [Command] = [
        Command(id: "memory.capture", title: "Capture a Thought", verb: "capture", needs: "text"),
        Command(id: "memory.search", title: "Search Memory", verb: "search", needs: "text"),
        Command(id: "memory.today", title: "Today", verb: "today", needs: nil),
        Command(id: "memory.tasks", title: "Open Tasks", verb: "tasks", needs: nil),
    ]

    // MARK: - Where things live

    /// `~/Library/Application Support/House/commands`, the one directory in
    /// the contract. Resolved through `FileManager`, not spelled out.
    public static func directory(
        applicationSupport: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
    ) -> URL? {
        applicationSupport?.appendingPathComponent("House/commands", isDirectory: true)
    }

    public static func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("\(appID).json", isDirectory: false)
    }

    public static func statusURL(in directory: URL) -> URL {
        directory.appendingPathComponent("\(appID).status.json", isDirectory: false)
    }

    /// Where `recall` is on this Mac, or nil when it is not installed.
    ///
    /// The configured path is asked first, then every directory on `PATH`,
    /// then the two prefixes a house CLI is installed under. No home directory
    /// is written down here: `ToolPaths` builds its default from
    /// `NSHomeDirectory()`, and the rest comes from the environment.
    public static func resolveEndpoint(
        tools: ToolPaths = .installed,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let fromPath = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { String($0) + "/recall" }
        let candidates = [tools.recall] + fromPath + ["/usr/local/bin/recall", "/opt/homebrew/bin/recall"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The manifest for this Mac, or nil when `recall` is not installed. An
    /// app with no endpoint publishes nothing: an entry naming a binary that
    /// is not there would only be a row that fails when picked.
    public static func document(
        tools: ToolPaths = .installed,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        directory: URL
    ) -> Document? {
        guard let endpoint = resolveEndpoint(tools: tools, environment: environment) else { return nil }
        return Document(
            schema: schema,
            app: appID,
            name: appName,
            transport: transport,
            endpoint: endpoint,
            status: statusURL(in: directory).path,
            commands: commands
        )
    }

    /// The status document, from state the app is already holding.
    public static func status(headline: String, endpoint: String?) -> Status {
        Status(
            app: appID,
            ok: endpoint.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false,
            busy: false,
            detail: headline
        )
    }

    // MARK: - Writing

    /// What one publish did, so the caller can log it. A failure is a log
    /// line and nothing else: losing remote control must never cost the menu
    /// bar its primary function.
    public enum Outcome: Equatable, Sendable {
        case wrote(String)
        /// Nothing was written, and why.
        case skipped(String)
        case failed(String)
    }

    /// Write the manifest. Returns what happened; it never throws at the app.
    public static func publish(
        tools: ToolPaths = .installed,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        directory: URL? = CommandManifest.directory()
    ) -> Outcome {
        guard let directory else { return .skipped("no Application Support directory") }
        guard let document = document(tools: tools, environment: environment, directory: directory) else {
            return .skipped("recall is not installed, so Memory publishes no commands")
        }
        return write(document, to: manifestURL(in: directory))
    }

    /// Write the status document beside the manifest.
    public static func publishStatus(
        headline: String,
        tools: ToolPaths = .installed,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        directory: URL? = CommandManifest.directory()
    ) -> Outcome {
        guard let directory else { return .skipped("no Application Support directory") }
        let endpoint = resolveEndpoint(tools: tools, environment: environment)
        return write(status(headline: headline, endpoint: endpoint), to: statusURL(in: directory))
    }

    /// One atomic write, with the directory made first. Sorted keys and no
    /// escaped slashes, so the same state produces the same bytes and a diff
    /// of the file means the commands really changed.
    static func write<T: Encodable>(_ value: T, to url: URL) -> Outcome {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            var data = try encoder.encode(value)
            data.append(0x0A)
            try data.write(to: url, options: .atomic)
            return .wrote(url.path)
        } catch {
            return .failed("\(url.path): \(error.localizedDescription)")
        }
    }
}
