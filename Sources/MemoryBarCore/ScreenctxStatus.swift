import Foundation

/// What `NO_COLOR=1 screenctx collect`'s sibling `screenctx status` printed,
/// read back into fields.
///
/// screenctx follows the house terminal style (design-system/DESIGN.md,
/// "Terminal surfaces"): one status line first, `●` then parts joined by ` · `,
/// then uppercase section labels over key and value lines at two spaces of
/// indent. Only the status line has no colon; the key lines all do. That is
/// the whole grammar this parser needs, and it is the same grammar
/// `memory-screen.py` parses, so neither of us invents a second one.
///
/// Nothing here re-spells a value. The frame count, the size, and the tick age
/// are carried as the strings screenctx chose, so Memory and the terminal
/// always say the same words.
public struct ScreenctxStatus: Equatable, Sendable {

    /// The word screenctx put first on the status line.
    public enum State: String, Equatable, Sendable {
        /// A tick landed inside the collector's staleness window.
        case collecting = "Collecting"
        /// The store exists but no tick is recent: the job is down or wedged.
        case stopped = "Stopped"
        /// No store on disk yet.
        case noStore = "No store"
        /// The status line did not start with a word we know.
        case unknown = ""
    }

    public var state: State
    /// `1,167 frames`, verbatim.
    public var framesText: String?
    /// `153.0 MB`, verbatim.
    public var sizeText: String?
    /// `last tick just now`, `last tick 4m ago`, or `no ticks yet`, verbatim.
    public var tickText: String?
    /// The front app at the last tick, when the line carried one.
    public var frontApp: String?
    /// `accessibility: granted`. Nil when the block did not print.
    ///
    /// Parsed, not trusted: TCC answers this line for the process that ran
    /// `screenctx status`, which is Memory.app when Memory runs it. The
    /// collector's own grant comes from its log (`CollectorLog.accessibility`).
    public var accessibilityGranted: Bool?
    public var storePath: String?
    public var schema: String?
    public var databaseSize: String?
    /// The whole status line, for the cases nothing else explains.
    public var statusLine: String

    public init(
        state: State = .unknown,
        framesText: String? = nil,
        sizeText: String? = nil,
        tickText: String? = nil,
        frontApp: String? = nil,
        accessibilityGranted: Bool? = nil,
        storePath: String? = nil,
        schema: String? = nil,
        databaseSize: String? = nil,
        statusLine: String = ""
    ) {
        self.state = state
        self.framesText = framesText
        self.sizeText = sizeText
        self.tickText = tickText
        self.frontApp = frontApp
        self.accessibilityGranted = accessibilityGranted
        self.storePath = storePath
        self.schema = schema
        self.databaseSize = databaseSize
        self.statusLine = statusLine
    }

    // MARK: - Parsing

    /// Read one `screenctx status` run. Never throws and never guesses: a part
    /// that is not on the line stays nil, and the caller says "unknown" rather
    /// than inventing a number.
    public static func parse(_ output: String) -> ScreenctxStatus {
        var status = ScreenctxStatus()
        var section = ""

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("●") {
                status.parseStatusLine(trimmed)
                continue
            }

            // A section label is an unindented, all-uppercase word.
            if !line.hasPrefix(" "), trimmed == trimmed.uppercased(), !trimmed.contains(":") {
                section = trimmed
                continue
            }

            guard let (key, value) = keyValue(trimmed) else { continue }
            switch (section, key) {
            case ("PERMISSIONS", "accessibility"):
                status.accessibilityGranted = value == "granted"
            case ("STORE", "store"):
                // A store that does not exist yet prints a trailing note.
                status.storePath = value.components(separatedBy: "  ").first
            case ("STORE", "schema"):
                status.schema = value
            case ("STORE", "db size"):
                status.databaseSize = value
            default:
                continue
            }
        }
        return status
    }

    /// `● Collecting · 1,167 frames · 153.0 MB · last tick just now · Quick Launch`
    private mutating func parseStatusLine(_ line: String) {
        let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
        statusLine = body
        let parts = body.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first else { return }
        state = State(rawValue: first) ?? .unknown

        for part in parts.dropFirst() {
            if part.hasSuffix(" frames") || part.hasSuffix(" frame") {
                framesText = part
            } else if part.hasSuffix(" MB") || part.hasSuffix(" GB") || part.hasSuffix(" KB") {
                sizeText = part
            } else if part.hasPrefix("last tick ") || part == "no ticks yet" {
                tickText = part
            } else if !part.isEmpty {
                // Whatever is left on the line is the app screenctx last saw.
                frontApp = part
            }
        }
    }

    /// Split `store:         /path` on its first colon. Nil for a line with no
    /// colon, which by the house rule is never a key and value line.
    static func keyValue(_ line: String) -> (key: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    // MARK: - Reading

    /// Run `screenctx status` and parse it. Blocking: call it off the main
    /// thread. Nil when the binary is not installed, so the panel can say that
    /// instead of showing a zeroed status.
    public static func read(tools: ToolPaths = .installed) -> ScreenctxStatus? {
        guard tools.exists(tools.screenctx) else { return nil }
        let result = Subprocess.run(executable: tools.screenctx, arguments: ["status"], timeout: 20)
        guard !result.stdout.isEmpty else { return nil }
        return parse(result.stdout)
    }
}
