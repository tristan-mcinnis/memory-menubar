import Foundation

/// The collector's two grants, Screen Recording and Accessibility, read from
/// the collector's own log.
///
/// `screenctx status` reports Accessibility but not Screen Recording, and
/// Memory must not probe for it itself: `CGPreflightScreenCaptureAccess`
/// answers for the calling process, so Memory asking would report Memory's
/// grant and say nothing true about the collector. What is honest is what the
/// collector wrote about itself. It probes with a real ScreenCaptureKit call
/// at start and every 60 s while denied, and prints one of two lines:
///
///     screenctx: Screen Recording granted (SCK probe ok)
///     screenctx: Screen Recording NOT granted (SCK probe failed) — …
///
/// The last of those in the log is the answer. No line means unknown, and
/// unknown is shown as unknown.
///
/// Accessibility is read the same way, for the same reason. `screenctx
/// status` does print an `accessibility:` line, but it comes from
/// `AXIsProcessTrusted()` inside the status process, and TCC answers that for
/// the responsible process: when Memory runs `screenctx status`, that is
/// Memory.app, not the collector. The collector itself, at each launch, loops
/// on
///
///     screenctx: waiting for Accessibility permission (System Settings → …)
///
/// every 30 s until it is trusted, and only then prints its Screen Recording
/// verdict and `screenctx collecting every …`. So whichever of those comes
/// last says whether the running collector got past its Accessibility gate.
/// A grant revoked while the collector runs does not print anything; the tick
/// state (skips, then Stopped) is what shows that.
public enum CollectorLog {

    public enum ScreenRecording: Equatable, Sendable {
        case granted
        case missing
        /// The log had nothing to say, or could not be read.
        case unknown
    }

    static let grantedMarker = "Screen Recording granted"
    static let missingMarker = "Screen Recording NOT granted"

    public enum Accessibility: Equatable, Sendable {
        /// The collector passed its Accessibility gate at its latest launch.
        case granted
        /// The collector is waiting for the grant.
        case missing
        /// The log had nothing to say, or could not be read.
        case unknown
    }

    static let accessibilityWaitMarker = "waiting for Accessibility permission"
    static let collectingMarker = "screenctx collecting every"

    /// The last Accessibility verdict in a chunk of log text. A wait line
    /// means missing; a Screen Recording verdict or the collecting line means
    /// the gate before them was passed.
    public static func accessibility(inLog text: String) -> Accessibility {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            if line.contains(accessibilityWaitMarker) { return .missing }
            if line.contains(collectingMarker) || line.contains(grantedMarker) || line.contains(missingMarker) {
                return .granted
            }
        }
        return .unknown
    }

    /// Both verdicts, from one read of the log's tail.
    public struct Verdicts: Equatable, Sendable {
        public var screenRecording: ScreenRecording
        public var accessibility: Accessibility

        public static let unknown = Verdicts(screenRecording: .unknown, accessibility: .unknown)
    }

    /// The last verdict in a chunk of log text.
    public static func screenRecording(inLog text: String) -> ScreenRecording {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            if line.contains(missingMarker) { return .missing }
            if line.contains(grantedMarker) { return .granted }
        }
        return .unknown
    }

    /// How much of the log's tail to read. The collector writes a line per
    /// permission change, not per tick, so the verdict is near the end; 64 KB
    /// is generous and bounded.
    public static let tailBytes = 64 * 1024

    /// Read the tail of the log file at `path`.
    ///
    /// Only the last `tailBytes` are read, so a log that has grown for weeks
    /// costs the same as a fresh one. A cut in the middle of a UTF-8 sequence
    /// is decoded leniently and the partial first line is dropped by the
    /// line split.
    public static func tail(ofFileAt path: String, bytes: Int = tailBytes) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil else { return nil }
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The collector's Screen Recording and Accessibility state, from its
    /// log file.
    public static func verdicts(logPath: String?) -> Verdicts {
        guard let logPath, let text = tail(ofFileAt: logPath) else { return .unknown }
        return Verdicts(screenRecording: screenRecording(inLog: text), accessibility: accessibility(inLog: text))
    }
}
