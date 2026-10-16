import Foundation

/// What the `recall` CLI hands back.
///
/// `search` and `today` are read through `--json` (added to recall on
/// 2026-09-03 for this app): one line, sorted keys. The text output is the
/// human contract and Memory does not parse it, so a change to a column width
/// can never break the panel.
///
/// `search` is `schema_version` 1. `today` is `schema_version` 3: version 2
/// made its `tasks` field three exclusive day sections (due today, overdue, in
/// progress), and version 3 gave that object the full open-backlog count and
/// lane counts and added the unresolved-triage summary. Both verbs are read at
/// exactly the version this app was written against: a payload that declares
/// another one is refused from its envelope, before the body is decoded, so a
/// moved contract reports one plain sentence rather than a decoder complaint
/// printed over truncated JSON.
///
/// `capture` has no JSON mode and needs none: its whole answer is one house
/// status line, and the only thing Memory shows is the sentence after the dot.
public enum RecallOutput {

    /// The versions this app was written against, and the only ones it reads.
    /// A payload declaring anything else is refused by the gate in `decode`.
    public static let expectedSearchSchemaVersion = 1
    public static let expectedTodaySchemaVersion = 3

    // MARK: - Search

    public struct SearchResult: Decodable, Equatable, Sendable {
        public let schemaVersion: Int
        public let query: String
        public let fileCount: Int
        public let count: Int
        public let scanMs: Int
        public let rankMs: Int
        public let hits: [Hit]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case query
            case fileCount = "file_count"
            case count
            case scanMs = "scan_ms"
            case rankMs = "rank_ms"
            case hits
        }
    }

    public struct Hit: Decodable, Equatable, Sendable, Identifiable {
        public let line: String
        public let path: String
        public let absolutePath: String
        public let lineNumber: Int
        public let day: String
        public let score: Int

        enum CodingKeys: String, CodingKey {
            case line
            case path
            case absolutePath = "absolute_path"
            case lineNumber = "line_number"
            case day
            case score
        }

        /// Stable within one result set: a file and line name a hit once.
        public var id: String { "\(absolutePath):\(lineNumber)" }

        /// The dim second column of a result row: when it was touched, and
        /// where it lives. The path is the long half, so it comes last and is
        /// truncated from the head by the view.
        public var detail: String { "\(day)  \(path):\(lineNumber)" }
    }

    // MARK: - Today

    public struct Today: Decodable, Equatable, Sendable {
        public let schemaVersion: Int
        public let captures: Section<Capture>
        public let tasks: TaskSections
        public let triage: Triage

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case captures
            case tasks
            case triage
        }

        public init(
            schemaVersion: Int = expectedTodaySchemaVersion,
            captures: Section<Capture>,
            tasks: TaskSections,
            triage: Triage
        ) {
            self.schemaVersion = schemaVersion
            self.captures = captures
            self.tasks = tasks
            self.triage = triage
        }
    }

    /// One `today` section. `readable == false` means the sanctioned read
    /// interface was not there, and `reason` is recall's own words for why.
    /// An unreadable section is never drawn as an empty one.
    public struct Section<Item: Decodable & Equatable & Sendable>: Decodable, Equatable, Sendable {
        public let readable: Bool
        public let reason: String?
        public let items: [Item]

        public init(readable: Bool, reason: String? = nil, items: [Item]) {
            self.readable = readable
            self.reason = reason
            self.items = items
        }
    }

    /// The task half of `today`: the three exclusive day sections plus the
    /// whole board they were drawn from. `readable` is true when at least one
    /// canonical backend answered; `reason` names the backend that did not, so
    /// a partial read is still shown and never passes for a complete one.
    /// `openCount` and `laneCounts` describe the full open backlog, not the
    /// three sections: a future-dated or undated task is counted there and
    /// appears in none of the sections.
    public struct TaskSections: Decodable, Equatable, Sendable {
        public let readable: Bool
        public let reason: String?
        public let openCount: Int
        public let laneCounts: [String: Int]
        public let dueToday: [Task]
        public let overdue: [Task]
        public let inProgress: [Task]

        enum CodingKeys: String, CodingKey {
            case readable
            case reason
            case openCount = "open_count"
            case laneCounts = "lane_counts"
            case dueToday = "due_today"
            case overdue
            case inProgress = "in_progress"
        }

        public init(
            readable: Bool,
            reason: String? = nil,
            openCount: Int = 0,
            laneCounts: [String: Int] = [:],
            dueToday: [Task] = [],
            overdue: [Task] = [],
            inProgress: [Task] = []
        ) {
            self.readable = readable
            self.reason = reason
            self.openCount = openCount
            self.laneCounts = laneCounts
            self.dueToday = dueToday
            self.overdue = overdue
            self.inProgress = inProgress
        }

        /// Every curated task, in the order the sections are read.
        public var all: [Task] { dueToday + overdue + inProgress }
    }

    /// The unresolved vault triage queue, summarised. `count` is how many
    /// captures are still unrouted and `oldest` is the owner CLI's own
    /// `captured_at` stamp for the oldest one, empty when the queue is empty.
    /// `readable: false` plus a `reason` means the owner CLI could not be read,
    /// so an unreadable queue is never drawn as an empty one.
    public struct Triage: Decodable, Equatable, Sendable {
        public let readable: Bool
        public let reason: String?
        public let count: Int
        public let oldest: String

        public init(readable: Bool, reason: String? = nil, count: Int = 0, oldest: String = "") {
            self.readable = readable
            self.reason = reason
            self.count = count
            self.oldest = oldest
        }
    }

    public struct Capture: Decodable, Equatable, Sendable, Identifiable {
        public let time: String
        public let text: String
        public let kind: String

        public init(time: String, text: String, kind: String) {
            self.time = time
            self.text = text
            self.kind = kind
        }

        public var id: String { "\(time)\u{1F}\(text)" }
    }

    /// One curated task from the day's three sections. Every field recall
    /// prints is kept; the panel decides which of them fit in 300 px.
    public struct Task: Decodable, Equatable, Sendable, Identifiable {
        /// The backend's own id. `id` below is the row's identity, which adds
        /// the owning file so two stores cannot collide.
        public let taskID: String
        public let title: String
        public let lane: String
        /// `YYYY-MM-DD`, or empty when the task has no due date.
        public let due: String
        public let project: String
        /// The owning file (`…/00-tasks.md`) or record path.
        public let source: String
        /// `vault` or `memory`, as the backend reported it.
        public let backend: String

        enum CodingKeys: String, CodingKey {
            case taskID = "id"
            case title
            case lane
            case due
            case project
            case source
            case backend
        }

        public init(
            taskID: String,
            title: String,
            lane: String,
            due: String,
            project: String,
            source: String,
            backend: String
        ) {
            self.taskID = taskID
            self.title = title
            self.lane = lane
            self.due = due
            self.project = project
            self.source = source
            self.backend = backend
        }

        /// Stable within one result set: the owning file and the backend's id,
        /// or its title when an older/malformed backend row has no id. This
        /// mirrors recall's own deduplication identity, so two id-less tasks in
        /// one file do not collapse into one SwiftUI row.
        public var id: String { "\(source)\u{1F}\(taskID.isEmpty ? title : taskID)" }

        /// The dim detail beside a task title: the project and lane `recall`
        /// prints, plus the due date when the task has one. The section label
        /// already says due today, overdue, or in progress, but the date is
        /// what the CLI's trailing column carries, so it stays.
        public var detail: String {
            ([project, lane] + (due.isEmpty ? [] : [due])).joined(separator: " · ")
        }
    }

    /// recall's JSON refusal: `{"error": "no memory repo at ~/notes"}`.
    public struct Failure: Decodable, Equatable, Sendable {
        public let error: String
    }

    // MARK: - Decoding

    /// The only field the version gate reads. `schema_version` sits in every
    /// envelope this app consumes, so it can be read without knowing the body
    /// that follows it.
    private struct VersionProbe: Decodable {
        let schemaVersion: Int

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
        }
    }

    /// Decode a `--json` payload at exactly `expectedVersion`, or the refusal
    /// recall prints instead.
    ///
    /// The refusal is checked first, because a refusal envelope declares
    /// `schema_version` 1 and is still recall's own answer. Then the version:
    /// a payload at another version is refused by its envelope before the body
    /// is decoded, so a moved contract reads as one plain sentence instead of
    /// a decoder complaint printed over truncated JSON. A run that produced
    /// neither is reported with what it did print, so the panel can show the
    /// real reason rather than "no results".
    public static func decode<T: Decodable>(
        _ type: T.Type,
        expectedVersion: Int,
        from result: CommandResult
    ) -> Result<T, RecallError> {
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.noOutput(stderr.isEmpty ? "recall printed nothing" : stderr))
        }
        let data = Data(text.utf8)
        if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
            return .failure(.refused(failure.error))
        }
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
           probe.schemaVersion != expectedVersion {
            return .failure(.versionMismatch(
                "recall reported schema \(probe.schemaVersion); Memory reads schema \(expectedVersion)"
            ))
        }
        if let value = try? JSONDecoder().decode(type, from: data) {
            return .success(value)
        }
        return .failure(.unreadable(String(text.prefix(200))))
    }

    public enum RecallError: Error, Equatable, Sendable {
        /// recall said no, in its own words.
        case refused(String)
        /// recall printed something that is not its JSON.
        case unreadable(String)
        /// recall printed nothing at all.
        case noOutput(String)
        /// The binary is not installed.
        case notInstalled(String)
        /// The payload is a schema version this build does not read. One plain
        /// sentence, never a dump of the payload.
        case versionMismatch(String)

        public var message: String {
            switch self {
            case let .refused(text): return text
            case let .unreadable(text): return "unexpected output: \(text)"
            case let .noOutput(text): return text
            case let .notInstalled(path): return "recall is not installed at \(path)"
            case let .versionMismatch(text): return text
            }
        }
    }

    // MARK: - Capture

    /// What `recall capture` reported. The message is the sentence after the
    /// house status dot, which is recall's own account of where the thought
    /// went, never a sentence Memory made up.
    public struct CaptureOutcome: Equatable, Sendable {
        public let ok: Bool
        public let message: String
    }

    /// Read one `recall capture` run. The status line is `● <message>`; the
    /// exit code decides whether it is a confirmation or a refusal.
    public static func captureOutcome(from result: CommandResult) -> CaptureOutcome {
        let text = (result.stdout.isEmpty ? result.stderr : result.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        var message = firstLine.trimmingCharacters(in: .whitespaces)
        if message.hasPrefix("●") {
            message = String(message.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if message.isEmpty {
            message = result.succeeded ? "captured" : "recall failed (exit \(result.exitCode))"
        }
        return CaptureOutcome(ok: result.succeeded, message: message)
    }

    // MARK: - Running

    /// `recall search <query> --json`. Blocking: call it off the main thread.
    public static func search(_ query: String, tools: ToolPaths = .installed) -> Result<SearchResult, RecallError> {
        run(
            ["search", query, "--json"], tools: tools,
            expectedVersion: expectedSearchSchemaVersion, as: SearchResult.self
        )
    }

    /// `recall today --json`. Blocking: call it off the main thread.
    public static func today(tools: ToolPaths = .installed) -> Result<Today, RecallError> {
        run(
            ["today", "--json"], tools: tools,
            expectedVersion: expectedTodaySchemaVersion, as: Today.self
        )
    }

    /// `recall capture <text>`. Blocking: call it off the main thread.
    ///
    /// `capture` is recall's capture verb. Its old name, `remember`, is a
    /// hidden alias in recall; the house keeps "remember" for ledger and
    /// `memory-remember.py` (see house-system's glossary). Every recall this
    /// app has shipped against accepts `capture`, so there is no fallback.
    public static func capture(_ text: String, tools: ToolPaths = .installed) -> CaptureOutcome {
        guard tools.exists(tools.recall) else {
            return CaptureOutcome(ok: false, message: "recall is not installed at \(tools.recall)")
        }
        // The thought is one argument. It is never joined into a command
        // string, so a quote or a semicolon in a captured thought is text.
        return captureOutcome(from: Subprocess.run(
            executable: tools.recall, arguments: ["capture", text], timeout: 30
        ))
    }

    private static func run<T: Decodable>(
        _ arguments: [String],
        tools: ToolPaths,
        expectedVersion: Int,
        as type: T.Type
    ) -> Result<T, RecallError> {
        guard tools.exists(tools.recall) else { return .failure(.notInstalled(tools.recall)) }
        return decode(
            type,
            expectedVersion: expectedVersion,
            from: Subprocess.run(executable: tools.recall, arguments: arguments, timeout: 30)
        )
    }
}
