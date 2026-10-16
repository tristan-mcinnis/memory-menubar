import XCTest
@testable import MemoryBar
import MemoryBarCore

/// What Return on a Today task row does, and the one confirmation rule that
/// panel open owns. Memory writes no task store: it opens the owning markdown
/// file with the same native mechanism the Collector log row uses, or puts a
/// precise request on the clipboard for a source a person cannot act in.
@MainActor
final class TodayActionTests: XCTestCase {

    private func task(
        _ id: String,
        source: String,
        lane: String = "captured",
        project: String = "alpha",
        title: String? = nil
    ) -> RecallOutput.Task {
        RecallOutput.Task(
            taskID: id,
            title: title ?? "Task \(id)",
            lane: lane,
            due: "",
            project: project,
            source: source,
            backend: source.hasSuffix(".jsonl") ? "memory" : "vault"
        )
    }

    private func model() -> PanelModel {
        let model = PanelModel(defaults: UserDefaults(suiteName: "TodayActionTests-\(UUID().uuidString)")!)
        model.backgroundRefresh = {}
        return model
    }

    private func today(_ tasks: [RecallOutput.Task]) -> RecallOutput.Today {
        RecallOutput.Today(
            captures: RecallOutput.Section(readable: true, reason: nil, items: []),
            tasks: RecallOutput.TaskSections(readable: true, dueToday: tasks),
            triage: RecallOutput.Triage(readable: true)
        )
    }

    // MARK: - Which action a row offers

    func testAMarkdownSourceIsOpened() {
        let action = PanelModel.taskAction(
            for: task("t1", source: "/p/alpha/00-tasks.md"),
            isOpenable: { _ in true }
        )
        XCTAssertEqual(action, .openSource("/p/alpha/00-tasks.md"))
    }

    /// The memory backend's source is a `tasks.jsonl` record. Opening a store
    /// in an editor is a dead end, so the row copies a request instead.
    func testAStoreRecordIsNotOpened() {
        let record = task("t1", source: "/home/example/notes/projects/delta/tasks.jsonl")
        guard case let .copyRequest(request) = PanelModel.taskAction(for: record, isOpenable: { _ in false }) else {
            return XCTFail("expected a request to copy")
        }
        XCTAssertTrue(request.contains(record.taskID))
        XCTAssertTrue(request.contains(record.title))
        XCTAssertTrue(request.contains(record.source))
    }

    func testTheDefaultProbeRefusesANonMarkdownStore() {
        XCTAssertFalse(PanelModel.isOpenableSource("/home/example/notes/projects/delta/tasks.jsonl"))
        XCTAssertFalse(PanelModel.isOpenableSource(""))
    }

    // MARK: - The request

    /// The copied request carries the task's own identity, its owning file,
    /// its lane and its project, so pasting it into Pi needs no follow-up.
    func testTheRequestNamesTheTaskItsFileItsLaneAndItsID() {
        let vaultTask = task(
            "fixture-task-three",
            source: "/home/example/notes/projects/beta/00-tasks.md",
            lane: "in_progress",
            project: "beta",
            title: "Fixture task three"
        )

        XCTAssertEqual(
            PanelModel.taskRequest(for: vaultTask),
            "Take up the task \"Fixture task three\" in "
                + "/home/example/notes/projects/beta/00-tasks.md "
                + "(project beta, lane in_progress, id fixture-task-three)."
        )
    }

    func testARequestWithNothingButATitleIsStillASentence() {
        let bare = RecallOutput.Task(
            taskID: "", title: "Something", lane: "", due: "", project: "", source: "", backend: ""
        )
        XCTAssertEqual(PanelModel.taskRequest(for: bare), "Take up the task \"Something\".")
    }

    // MARK: - Running it

    func testReturnOnAStoreRecordCopiesTheRequestAndReturnsToTheRows() {
        let pasteboard = NSPasteboard.general
        let prior = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let prior { pasteboard.setString(prior, forType: .string) }
        }

        let model = model()
        let record = task("t1", source: "/p/records/tasks.jsonl")
        model.mode = .today
        model.override(today: today([record]))
        model.selection = 0

        model.runSelection()

        XCTAssertEqual(model.mode, .rows)
        XCTAssertEqual(model.selection, 0)
        XCTAssertEqual(model.confirmation?.text, "Copied a request for Task t1")
        XCTAssertTrue(model.confirmation?.ok ?? false)
        XCTAssertEqual(pasteboard.string(forType: .string), PanelModel.taskRequest(for: record))
    }

    func testBeginningTodayResetsSelectionToTheFirstTask() {
        let model = model()
        model.selection = 7

        model.beginToday()

        XCTAssertEqual(model.selection, 0)
    }

    func testReturnOnAnEmptySelectionDoesNothing() {
        let model = model()
        model.mode = .today
        model.override(today: today([]))
        model.selection = 3

        model.runSelection()

        XCTAssertEqual(model.mode, .today)
        XCTAssertNil(model.confirmation)
    }

    // MARK: - A confirmation belongs to the open it finished in

    func testReopeningThePanelClearsAStaleConfirmation() {
        let model = model()
        model.confirmation = Confirmation(ok: true, text: "appended to inbox/2026-09-03.md")

        model.panelOpened()

        XCTAssertNil(model.confirmation)
    }
}
