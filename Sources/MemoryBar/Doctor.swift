import Foundation
import MemoryBarCore

/// `memory-bar --doctor`: run every read the panel makes and print what came
/// back, then exit. Memory has no window worth opening to check whether its
/// wiring works, and a menu-bar app that silently shows "Checking…" forever is
/// exactly the failure this catches.
///
/// Read-only. It never toggles the collector, never captures a thought, and
/// never opens a window. Output follows the house terminal style
/// (design-system/DESIGN.md, "Terminal surfaces"): one status line first, then
/// key and value blocks at two spaces of indent.
enum Doctor {

    /// 0 when every read succeeded, 1 when any of them did not.
    static func run(tools: ToolPaths = .installed, agent: LaunchAgent = .screenctx) -> Int32 {
        var ok = true

        let snapshot = CollectorSnapshot.read(agent: agent, tools: tools)
        // The dot is the only colour a house CLI prints, and this one is
        // never styled: `--doctor` is read off a pipe as often as off a
        // terminal, and the word beside it carries the meaning anyway.
        print("● \(snapshot.headline)" + (snapshot.context.map { " · \($0)" } ?? ""))

        print("")
        print("COLLECTOR")
        block([
            ("health", "\(snapshot.health)"),
            ("bootstrapped", snapshot.isBootstrapped ? "yes" : "no"),
            ("job", agent.label),
            ("plist", agent.plistPath),
            ("log", agent.definition()?.logPath ?? "not declared"),
            ("store", snapshot.storePath ?? "not reported"),
            ("screenctx", tools.exists(tools.screenctx) ? tools.screenctx : "NOT INSTALLED (\(tools.screenctx))"),
        ])
        if !tools.exists(tools.screenctx) { ok = false }

        print("")
        print("RECALL")
        var recallRows: [(String, String)] = [
            ("recall", tools.exists(tools.recall) ? tools.recall : "NOT INSTALLED (\(tools.recall))"),
        ]
        switch RecallOutput.today(tools: tools) {
        case let .success(today):
            recallRows.append((
                "today",
                schemaLine(today.schemaVersion, expected: RecallOutput.expectedTodaySchemaVersion)
                    + " · "
                    + "\(today.captures.readable ? "\(today.captures.items.count) captures" : "captures unreadable") · "
                    + taskSummary(today.tasks)
            ))
            recallRows.append(("triage", triageSummary(today.triage)))
            if today.schemaVersion != RecallOutput.expectedTodaySchemaVersion { ok = false }
        case let .failure(error):
            recallRows.append(("today", "FAILED: \(error.message)"))
            ok = false
        }
        switch RecallOutput.search("memory", tools: tools) {
        case let .success(result):
            recallRows.append((
                "search",
                schemaLine(result.schemaVersion, expected: RecallOutput.expectedSearchSchemaVersion)
                    + " · \(result.count) hits over \(result.fileCount) files"
                    + " · scan \(result.scanMs) ms · rank \(result.rankMs) ms"
            ))
            if result.schemaVersion != RecallOutput.expectedSearchSchemaVersion { ok = false }
        case let .failure(error):
            recallRows.append(("search", "FAILED: \(error.message)"))
            ok = false
        }
        block(recallRows)

        return ok ? 0 : 1
    }

    /// The declared schema, with the version this build expects when they
    /// differ, so a drifted contract is named rather than printed as ordinary.
    private static func schemaLine(_ actual: Int, expected: Int) -> String {
        actual == expected ? "schema \(actual)" : "schema \(actual) (expected \(expected))"
    }

    /// The task half of a today line: the three curated counts and the whole
    /// open board behind them when it was readable, or recall's own reason
    /// when it was not, so a partial read is never reported as a full one.
    private static func taskSummary(_ tasks: RecallOutput.TaskSections) -> String {
        guard tasks.readable else { return "tasks unreadable" }
        let counts = "\(tasks.dueToday.count) due today · \(tasks.overdue.count) overdue"
            + " · \(tasks.inProgress.count) in progress · \(tasks.openCount) open"
        return tasks.reason.map { "\(counts) · partial: \($0)" } ?? counts
    }

    /// The unresolved-triage line: how many captures are still unrouted and
    /// how old the oldest is, or the owner CLI's own reason when it could not
    /// be read.
    private static func triageSummary(_ triage: RecallOutput.Triage) -> String {
        guard triage.readable else { return "unreadable: \(triage.reason ?? "no reason reported")" }
        guard triage.count > 0 else { return "none unresolved" }
        let noun = triage.count == 1 ? "capture" : "captures"
        guard let day = PanelModel.shortDay(triage.oldest) else {
            return "\(triage.count) unresolved \(noun)"
        }
        return "\(triage.count) unresolved \(noun) · oldest \(day)"
    }

    private static func block(_ pairs: [(String, String)]) {
        let width = (pairs.map(\.0.count).max() ?? 0) + 2
        for (key, value) in pairs {
            print("  " + key + String(repeating: " ", count: max(1, width - key.count)) + value)
        }
    }
}
