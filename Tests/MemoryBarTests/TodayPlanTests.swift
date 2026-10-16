import XCTest
@testable import MemoryBar
import MemoryBarCore

/// The Today glance spends one row budget across three curated task sections.
/// The split is a pure function of the sections and the budget, so the panel's
/// honesty about what did not fit is decided here and not in a view.
@MainActor
final class TodayPlanTests: XCTestCase {

    private func task(_ id: String, lane: String = "captured", due: String = "", project: String = "alpha") -> RecallOutput.Task {
        RecallOutput.Task(
            taskID: id, title: "Task \(id)", lane: lane, due: due, project: project,
            source: "/p/\(project)/00-tasks.md", backend: "vault"
        )
    }

    private func sections(
        dueToday: [RecallOutput.Task] = [],
        overdue: [RecallOutput.Task] = [],
        inProgress: [RecallOutput.Task] = [],
        openCount: Int = 0,
        laneCounts: [String: Int] = [:]
    ) -> RecallOutput.TaskSections {
        RecallOutput.TaskSections(
            readable: true, reason: nil,
            openCount: openCount, laneCounts: laneCounts,
            dueToday: dueToday, overdue: overdue, inProgress: inProgress
        )
    }

    private func capture(_ text: String) -> RecallOutput.Capture {
        RecallOutput.Capture(time: "09:15", text: text, kind: "note")
    }

    private func triage(
        count: Int = 0,
        oldest: String = "",
        readable: Bool = true,
        reason: String? = nil
    ) -> RecallOutput.Triage {
        RecallOutput.Triage(readable: readable, reason: reason, count: count, oldest: oldest)
    }

    private func today(
        captures: [RecallOutput.Capture] = [],
        capturesReadable: Bool = true,
        capturesReason: String? = nil,
        tasks: RecallOutput.TaskSections,
        triage: RecallOutput.Triage = RecallOutput.Triage(readable: true)
    ) -> RecallOutput.Today {
        RecallOutput.Today(
            captures: RecallOutput.Section(
                readable: capturesReadable, reason: capturesReason, items: captures
            ),
            tasks: tasks,
            triage: triage
        )
    }

    // MARK: - Budget

    /// Every non-empty section is visible before any section spends the
    /// leftover: a 300 px glance must not hide the overdue list behind a long
    /// run of due-today rows.
    func testEveryNonEmptySectionGetsARowBeforeTheLeftoverIsSpent() {
        let groups = PanelModel.todayTaskGroups(sections(
            dueToday: (1...5).map { task("d\($0)") },
            overdue: (1...3).map { task("o\($0)") },
            inProgress: [task("p1")]
        ), budget: 6)

        XCTAssertEqual(groups.map(\.label), ["Due today", "Overdue", "In progress"])
        XCTAssertEqual(groups.map(\.tasks.count), [4, 1, 1])
        XCTAssertEqual(groups.map(\.overflow), [1, 2, 0])
        XCTAssertTrue(groups.allSatisfy { !$0.tasks.isEmpty })
    }

    /// Once every section has its row, the leftover follows section priority:
    /// due today, then overdue, then in progress.
    func testTheLeftoverRowsFollowSectionPriority() {
        let groups = PanelModel.todayTaskGroups(sections(
            dueToday: (1...2).map { task("d\($0)") },
            overdue: (1...2).map { task("o\($0)") },
            inProgress: (1...2).map { task("p\($0)") }
        ), budget: 4)

        XCTAssertEqual(groups.map(\.tasks.count), [2, 1, 1])
        XCTAssertEqual(groups.map(\.overflow), [0, 1, 1])
    }

    func testOverflowCountsWhatDidNotFit() {
        let groups = PanelModel.todayTaskGroups(sections(
            overdue: (1...8).map { task("o\($0)") }
        ), budget: 3)

        XCTAssertEqual(groups[1].tasks.count, 3)
        XCTAssertEqual(groups[1].overflow, 5)
    }

    /// A section with nothing in it carries no rows and no overflow, but it
    /// still has its label and an honest empty line.
    func testAnEmptySectionHasNoRowsAndSaysSo() {
        let groups = PanelModel.todayTaskGroups(sections(overdue: [task("o1")]), budget: 8)

        XCTAssertEqual(groups[0].tasks, [])
        XCTAssertEqual(groups[0].overflow, 0)
        XCTAssertEqual(groups[0].emptyText, "nothing due today")
        XCTAssertEqual(groups[2].emptyText, "nothing in progress")
        XCTAssertTrue(groups[2].tasks.isEmpty)
    }

    func testAZeroBudgetShowsNoRowsAndCountsEverythingAsOverflow() {
        let groups = PanelModel.todayTaskGroups(sections(
            dueToday: [task("d1"), task("d2")],
            inProgress: [task("p1")]
        ), budget: 0)

        XCTAssertEqual(groups.map(\.tasks.count), [0, 0, 0])
        XCTAssertEqual(groups.map(\.overflow), [2, 0, 1])
    }

    func testTheThreeGroupsKeepTheSectionOrderEvenWhenOnlyOneHasRows() {
        let groups = PanelModel.todayTaskGroups(sections(inProgress: [task("p1")]), budget: 8)

        XCTAssertEqual(groups.map(\.label), ["Due today", "Overdue", "In progress"])
        XCTAssertEqual(groups.map(\.tasks.count), [0, 0, 1])
    }

    func testTodayTaskGroupsAreIdentifiedByTheirSectionLabel() {
        let groups = PanelModel.todayTaskGroups(sections(), budget: PanelModel.todayRowLimit)
        XCTAssertEqual(groups.map(\.id), ["Due today", "Overdue", "In progress"])
    }

    // MARK: - Status note

    /// An unreadable board says so in recall's words, in the danger colour.
    func testAnUnreadableTaskSectionNoteIsDangerousAndKeepsTheReason() {
        let note = PanelModel.todayTaskStatusNote(RecallOutput.TaskSections(
            readable: false, reason: "no read interface (taskTreeCLI disabled)"
        ))
        XCTAssertEqual(note, PanelModel.TodayNote(text: "no read interface (taskTreeCLI disabled)", danger: true))
    }

    func testAnUnreadableTaskSectionWithoutAReasonStillSaysSomethingTrue() {
        let note = PanelModel.todayTaskStatusNote(RecallOutput.TaskSections(readable: false))
        XCTAssertEqual(note, PanelModel.TodayNote(text: "tasks unreadable", danger: true))
    }

    /// A partial read stays readable and keeps its reason, quietly, so a good
    /// half of the board is never thrown away because one backend failed.
    func testAPartialReadNoteIsQuietAndNamesWhatFailed() {
        let note = PanelModel.todayTaskStatusNote(RecallOutput.TaskSections(
            readable: true, reason: "read failed (memory-tasks.py)"
        ))
        XCTAssertEqual(note, PanelModel.TodayNote(text: "tasks: read failed (memory-tasks.py)", danger: false))
    }

    func testAReadableBoardWithNoReasonHasNoNote() {
        XCTAssertNil(PanelModel.todayTaskStatusNote(RecallOutput.TaskSections(readable: true)))
    }

    func testAShortReasonIsKeptWhole() {
        XCTAssertEqual(PanelModel.clippedReason("read failed (memory-tasks.py)"), "read failed (memory-tasks.py)")
    }

    /// The cut lands on a space when one is near, so the visible head ends on a
    /// whole store rather than half a name.
    func testALongReasonIsCutAtAWordBoundaryWhenItCanBe() {
        let reason = String(repeating: "example-store-one (missing-path), ", count: 12)
        let clipped = PanelModel.clippedReason(reason)

        XCTAssertTrue(clipped.hasSuffix("…"))
        XCTAssertLessThanOrEqual(clipped.count, PanelModel.reasonClipLength + 1)
        XCTAssertTrue(clipped.dropLast().hasSuffix("),"), "got \(clipped.suffix(24))")
    }

    /// A reason with no space near the cut is still clipped at the limit: the
    /// line ends somewhere, and it says so.
    func testAReasonWithNoSpaceIsCutAtTheLimit() {
        let reason = String(repeating: "x", count: 300)
        let clipped = PanelModel.clippedReason(reason)

        XCTAssertEqual(clipped.count, PanelModel.reasonClipLength + 1)
        XCTAssertTrue(clipped.hasSuffix("…"))
        XCTAssertTrue(clipped.hasPrefix(String(repeating: "x", count: 40)))
    }

    // MARK: - Board health

    /// The backlog line names the board size and its two biggest lanes, so an
    /// empty day reads as an empty day and not as an empty board. A tie is
    /// broken by lane name, so the same board always reads the same way.
    func testTheBacklogLineNamesTheTwoBiggestLanesOnly() {
        let note = PanelModel.todayBacklogNote(sections(
            openCount: 12, laneCounts: ["b": 5, "a": 5, "c": 2]
        ))

        XCTAssertEqual(note?.text, "12 open in the backlog · a 5 · b 5")
        XCTAssertEqual(note?.danger, false)
    }

    func testAnEmptyBoardStillSaysItIsEmpty() {
        XCTAssertEqual(
            PanelModel.todayBacklogNote(sections(openCount: 0))?.text,
            "0 open in the backlog"
        )
    }

    /// A board that could not be read reports no count at all: zero open would
    /// be a number Memory never got back.
    func testNoBacklogCountIsDrawnWhenTheBoardCouldNotBeRead() {
        XCTAssertNil(PanelModel.todayBacklogNote(RecallOutput.TaskSections(readable: false, reason: "boom")))
    }

    // MARK: - Triage health

    func testTheTriageLineNamesTheCountAndTheOldestDay() {
        let note = PanelModel.todayTriageNote(triage(count: 4, oldest: "2026-09-02T15:14:08+08:00"))

        XCTAssertEqual(note?.text, "4 unresolved captures · oldest 2026-09-02")
        XCTAssertEqual(note?.danger, false)
    }

    func testOneUnresolvedCaptureIsSingular() {
        XCTAssertEqual(
            PanelModel.todayTriageNote(triage(count: 1, oldest: "2026-09-02T15:14:08+08:00"))?.text,
            "1 unresolved capture · oldest 2026-09-02"
        )
    }

    func testACountWithNoUsableStampStillSaysTheCount() {
        XCTAssertEqual(
            PanelModel.todayTriageNote(triage(count: 2, oldest: "not-a-stamp"))?.text,
            "2 unresolved captures"
        )
    }

    func testAnEmptyTriageQueueHasNoLine() {
        XCTAssertNil(PanelModel.todayTriageNote(triage(count: 0)))
    }

    func testAnUnreadableTriageQueueIsDangerousAndKeepsItsReason() {
        let note = PanelModel.todayTriageNote(triage(readable: false, reason: "read failed (memory-capture.py list --json)"))

        XCTAssertEqual(note?.text, "triage unreadable: read failed (memory-capture.py list --json)")
        XCTAssertEqual(note?.danger, true)
    }

    func testTheTriageDayIsTheFirstTenCharactersOfAnISOStamp() {
        XCTAssertEqual(PanelModel.shortDay("2026-09-02T15:14:08+08:00"), "2026-09-02")
        XCTAssertNil(PanelModel.shortDay(""))
        XCTAssertNil(PanelModel.shortDay("30 Aug 2026"))
    }

    // MARK: - The whole surface

    /// The health lines spend the same budget as the rows: two notes, three
    /// captures and the task sections together never exceed eight rows.
    func testTheHealthLinesSpendTheRowBudgetBeforeTheRows() {
        let plan = PanelModel.makeTodayPlan(today(
            captures: (1...3).map { capture("c\($0)") },
            tasks: sections(
                dueToday: (1...6).map { task("d\($0)") },
                openCount: 42,
                laneCounts: ["captured": 9, "requires_action": 17]
            ),
            triage: triage(count: 2, oldest: "2026-09-02T15:14:08+08:00")
        ), budget: 8)

        XCTAssertEqual(plan.notes.count, 2)
        XCTAssertEqual(plan.captures.count, 3)
        XCTAssertEqual(plan.taskRows.count, 3)
        XCTAssertEqual(plan.notes.count + plan.captures.count + plan.taskRows.count, 8)
    }

    /// The empty day: nothing due, nothing overdue, nothing in progress, and
    /// the two health lines that say the board is not empty and the triage
    /// queue is not clear.
    func testAnEmptyDayStillShowsTheBacklogAndTriageHealth() {
        let plan = PanelModel.makeTodayPlan(today(
            tasks: sections(openCount: 42, laneCounts: ["captured": 9, "requires_action": 17]),
            triage: triage(count: 4, oldest: "2026-09-02T15:14:08+08:00")
        ), budget: 8)

        XCTAssertEqual(plan.captureNote?.text, "no captures today")
        XCTAssertEqual(plan.backlogNote?.text, "42 open in the backlog · requires_action 17 · captured 9")
        XCTAssertEqual(plan.triageNote?.text, "4 unresolved captures · oldest 2026-09-02")
        XCTAssertEqual(plan.groups.map(\.tasks.count), [0, 0, 0])
        XCTAssertEqual(
            plan.groups.map(\.placeholder),
            ["nothing due today", "nothing overdue", "nothing in progress"]
        )
    }

    func testCapturesThatDidNotFitAreCountedAndNotSaidMissing() {
        let plan = PanelModel.makeTodayPlan(today(
            captures: [capture("a"), capture("b")],
            tasks: sections(openCount: 5)
        ), budget: 1)

        XCTAssertEqual(plan.notes.count, 1)
        XCTAssertTrue(plan.captures.isEmpty)
        XCTAssertEqual(plan.captureOverflow, 2)
    }

    func testAnUnreadableCaptureSectionKeepsItsReasonInThePlan() {
        let plan = PanelModel.makeTodayPlan(today(
            capturesReadable: false,
            capturesReason: "no read interface (captureCLI disabled)",
            tasks: sections(openCount: 3)
        ), budget: 8)

        XCTAssertEqual(plan.captureNote?.text, "no read interface (captureCLI disabled)")
        XCTAssertEqual(plan.captureNote?.danger, true)
        XCTAssertEqual(plan.captureOverflow, 0)
    }

    /// Three section labels over a failed read would be exactly the lie the
    /// note exists to stop, so an unreadable board draws no sections.
    func testAnUnreadableBoardDrawsNoSections() {
        let plan = PanelModel.makeTodayPlan(today(
            tasks: RecallOutput.TaskSections(readable: false, reason: "no read interface (taskTreeCLI disabled)")
        ), budget: 8)

        XCTAssertTrue(plan.groups.isEmpty)
        XCTAssertEqual(plan.taskNote?.text, "no read interface (taskTreeCLI disabled)")
        XCTAssertEqual(plan.taskNote?.danger, true)
        XCTAssertNil(plan.backlogNote)
    }

    // MARK: - Task selection

    /// The selection walks the task rows in draw order and skips everything
    /// else: a capture is not a row the keyboard can act on.
    func testTheTodaySelectionWalksTaskRowsOnly() {
        let model = PanelModel(defaults: UserDefaults(suiteName: "TodayPlanTests-\(UUID().uuidString)")!)
        model.mode = .today
        model.override(today: today(
            captures: [capture("c1")],
            tasks: sections(
                dueToday: [task("d1"), task("d2")],
                overdue: [task("o1")]
            )
        ))

        XCTAssertEqual(model.todayPlan?.taskRows.map(\.taskID), ["d1", "d2", "o1"])
        XCTAssertEqual(model.selection, 0)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, 1)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, 2)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selection, 0, "the list wraps")
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selection, 2, "and wraps the other way")
    }

    func testASectionThatDidNotFitSaysHowManyRatherThanNothing() {
        let groups = PanelModel.todayTaskGroups(sections(overdue: [task("o1"), task("o2")]), budget: 0)

        XCTAssertTrue(groups[1].tasks.isEmpty)
        XCTAssertEqual(groups[1].overflow, 2)
        XCTAssertEqual(groups[1].placeholder, "2 more")
    }

    func testAnEmptySectionKeepsItsEmptyLine() {
        let groups = PanelModel.todayTaskGroups(sections(), budget: 0)
        XCTAssertEqual(groups.map(\.placeholder), ["nothing due today", "nothing overdue", "nothing in progress"])
    }
}
