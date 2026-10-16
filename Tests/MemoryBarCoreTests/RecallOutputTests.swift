import XCTest
@testable import MemoryBarCore

/// The search and today surfaces read recall's `--json` contract. These run
/// against payloads the real binary printed.
final class RecallOutputTests: XCTestCase {

    private func decodeToday(_ fixture: String) -> Result<RecallOutput.Today, RecallOutput.RecallError> {
        RecallOutput.decode(
            RecallOutput.Today.self,
            expectedVersion: RecallOutput.expectedTodaySchemaVersion,
            from: CommandResult(exitCode: 0, stdout: Fixture.text(fixture), stderr: "")
        )
    }

    private func decodeSearch(_ fixture: String) -> Result<RecallOutput.SearchResult, RecallOutput.RecallError> {
        RecallOutput.decode(
            RecallOutput.SearchResult.self,
            expectedVersion: RecallOutput.expectedSearchSchemaVersion,
            from: CommandResult(exitCode: 0, stdout: Fixture.text(fixture), stderr: "")
        )
    }

    // MARK: - Search

    func testSearchPayloadDecodesEveryFieldARowShows() throws {
        guard case let .success(result) = decodeSearch("recall-search.json") else {
            return XCTFail("expected a search result")
        }

        XCTAssertEqual(result.schemaVersion, RecallOutput.expectedSearchSchemaVersion)
        XCTAssertEqual(result.query, "design system")
        XCTAssertEqual(result.count, result.hits.count)
        XCTAssertEqual(result.fileCount, 2)

        let hit = try XCTUnwrap(result.hits.first)
        XCTAssertEqual(hit.line, "- 09:15 the design system keeps every color in one file")
        XCTAssertEqual(hit.path, "inbox/2026-09-03.md")
        XCTAssertEqual(hit.lineNumber, 3)
        XCTAssertEqual(hit.day, "2026-09-03")
        XCTAssertTrue(hit.absolutePath.hasSuffix("/notes/inbox/2026-09-03.md"))
    }

    func testAHitsDetailPairsTheDayWithThePathAndLine() {
        guard case let .success(result) = decodeSearch("recall-search.json") else {
            return XCTFail("expected a search result")
        }
        XCTAssertEqual(result.hits[0].detail, "2026-09-03  inbox/2026-09-03.md:3")
    }

    func testHitIdentityIsTheFileAndLineSoTwoHitsInOneFileStayDistinct() {
        guard case let .success(result) = decodeSearch("recall-search.json") else {
            return XCTFail("expected a search result")
        }
        XCTAssertEqual(Set(result.hits.map(\.id)).count, result.hits.count)
        XCTAssertEqual(result.hits[0].id, "\(result.hits[0].absolutePath):3")
    }

    // MARK: - Today (schema v3)

    func testTodayPayloadDecodesCapturesTheThreeTaskSectionsAndTheBoardSummary() throws {
        guard case let .success(today) = decodeToday("recall-today.json") else {
            return XCTFail("expected a today glance")
        }

        XCTAssertEqual(today.schemaVersion, RecallOutput.expectedTodaySchemaVersion)
        XCTAssertTrue(today.captures.readable)
        XCTAssertTrue(today.tasks.readable)
        XCTAssertNil(today.tasks.reason)
        XCTAssertEqual(today.captures.items.count, 2)
        XCTAssertEqual(today.tasks.dueToday.count, 2)
        XCTAssertEqual(today.tasks.overdue.count, 1)
        XCTAssertEqual(today.tasks.inProgress.count, 1)

        // The whole open board, not the three day sections. A future-dated or
        // undated task is counted here and shown in none of the sections.
        XCTAssertEqual(today.tasks.openCount, 42)
        XCTAssertEqual(today.tasks.laneCounts["requires_action"], 17)
        XCTAssertEqual(today.tasks.laneCounts.values.reduce(0, +), today.tasks.openCount)

        let capture = try XCTUnwrap(today.captures.items.first)
        XCTAssertEqual(capture.time, "09:15")
        XCTAssertEqual(capture.text, "Fixture capture one")
    }

    /// The unresolved-triage summary keeps the owner CLI's count and its own
    /// `captured_at` stamp for the oldest capture, so the panel never has to
    /// parse or re-spell it.
    func testTheTriageSummaryKeepsItsCountAndOldestStamp() throws {
        guard case let .success(today) = decodeToday("recall-today.json") else {
            return XCTFail("expected a today glance")
        }

        XCTAssertTrue(today.triage.readable)
        XCTAssertNil(today.triage.reason)
        XCTAssertEqual(today.triage.count, 1)
        XCTAssertEqual(today.triage.oldest, "2026-09-02T15:14:08+08:00")
    }

    /// A triage queue that could not be read is readable: false plus recall's
    /// own reason, never an empty queue.
    func testAnUnreadableTriageQueueIsNotReportedAsEmpty() throws {
        guard case let .success(today) = decodeToday("recall-today-unreadable.json") else {
            return XCTFail("expected a today glance")
        }

        XCTAssertFalse(today.triage.readable)
        XCTAssertEqual(today.triage.reason, "no read interface (captureCLI disabled)")
        XCTAssertEqual(today.triage.count, 0)
    }

    /// Every field recall prints for a task survives the decode: the panel
    /// shows some of them and must never lose the rest.
    func testATodayTaskKeepsItsIDLaneDueProjectSourceAndBackend() throws {
        guard case let .success(today) = decodeToday("recall-today.json") else {
            return XCTFail("expected a today glance")
        }

        let overdue = try XCTUnwrap(today.tasks.overdue.first)
        XCTAssertEqual(overdue.taskID, "3f2a8c11-0b44-4e2f-9c3a-1d2e3f4a5b6c")
        XCTAssertEqual(overdue.title, "Fixture task seven")
        XCTAssertEqual(overdue.lane, "requires_action")
        XCTAssertEqual(overdue.due, "2026-09-10")
        XCTAssertEqual(overdue.project, "delta")
        XCTAssertEqual(overdue.source, "/home/example/notes/projects/delta/tasks.jsonl")
        XCTAssertEqual(overdue.backend, "memory")

        let inProgress = try XCTUnwrap(today.tasks.inProgress.first)
        XCTAssertEqual(inProgress.due, "", "an undated task keeps an empty due, not a missing one")
        XCTAssertEqual(inProgress.backend, "vault")
    }

    /// The dim line a task row shows, with the due date when the task has one.
    func testATaskDetailNamesTheProjectLaneAndDueDate() throws {
        guard case let .success(today) = decodeToday("recall-today.json") else {
            return XCTFail("expected a today glance")
        }

        XCTAssertEqual(today.tasks.overdue[0].detail, "delta · requires_action · 2026-09-10")
        XCTAssertEqual(today.tasks.inProgress[0].detail, "beta · in_progress")
    }

    /// Two tasks with the same backend id in different stores must stay two
    /// rows: the source half is half the identity.
    func testTaskIdentityPairsTheSourceWithTheBackendID() throws {
        guard case let .success(today) = decodeToday("recall-today.json") else {
            return XCTFail("expected a today glance")
        }
        let ids = today.tasks.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(today.tasks.overdue[0].id, "\(today.tasks.overdue[0].source)\u{1F}\(today.tasks.overdue[0].taskID)")
    }

    func testIdlessTasksInOneSourceFallBackToTheirTitlesForIdentity() {
        let first = RecallOutput.Task(
            taskID: "", title: "First", lane: "captured", due: "", project: "alpha",
            source: "/p/alpha/00-tasks.md", backend: "vault"
        )
        let second = RecallOutput.Task(
            taskID: "", title: "Second", lane: "captured", due: "", project: "alpha",
            source: "/p/alpha/00-tasks.md", backend: "vault"
        )
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.id, "/p/alpha/00-tasks.md\u{1F}First")
    }

    func testAnUnreadableTaskSectionCarriesRecallsOwnReasonAndIsNotAnEmptyOne() throws {
        guard case let .success(today) = decodeToday("recall-today-unreadable.json") else {
            return XCTFail("expected a today glance")
        }

        XCTAssertFalse(today.captures.readable)
        XCTAssertFalse(today.tasks.readable)
        XCTAssertEqual(today.captures.reason, "no read interface (captureCLI disabled)")
        XCTAssertEqual(today.tasks.reason, "no read interface (taskTreeCLI disabled)")
        XCTAssertTrue(today.captures.items.isEmpty)
        XCTAssertTrue(today.tasks.dueToday.isEmpty)
        XCTAssertTrue(today.tasks.all.isEmpty)
        // A board that could not be read reports no count at all, rather than
        // a zero that would read as an empty board.
        XCTAssertEqual(today.tasks.openCount, 0)
        XCTAssertTrue(today.tasks.laneCounts.isEmpty)
    }

    /// A partial read is readable and still worth showing: one backend
    /// answered, one did not, and the reason is kept rather than dropped.
    func testAPartialReadKeepsItsReasonWhileStayingReadable() throws {
        guard case let .success(today) = decodeToday("recall-today-partial.json") else {
            return XCTFail("expected a today glance")
        }

        XCTAssertTrue(today.tasks.readable)
        XCTAssertEqual(
            today.tasks.reason,
            "read failed (/home/example/notes/ops/memory-tasks.py list --registered --json)"
        )
        XCTAssertEqual(today.tasks.inProgress.count, 1)
    }

    // MARK: - The version gate

    /// The v2 payload the app used to read. Its `tasks` object has no
    /// `open_count`, no `lane_counts` and no `triage`, so decoding it as v3
    /// would fail inside the decoder. The gate refuses it by its envelope
    /// first, so the panel says one plain sentence instead of printing
    /// truncated JSON at the user.
    func testAV2TodayPayloadIsRefusedWithAPlainVersionMessage() {
        let result = RecallOutput.decode(
            RecallOutput.Today.self,
            expectedVersion: RecallOutput.expectedTodaySchemaVersion,
            from: CommandResult(exitCode: 0, stdout: Fixture.text("recall-today-v2.json"), stderr: "")
        )
        guard case let .failure(error) = result else { return XCTFail("expected a version refusal") }
        XCTAssertEqual(error, .versionMismatch("recall reported schema 2; Memory reads schema 3"))
        XCTAssertEqual(error.message, "recall reported schema 2; Memory reads schema 3")
        XCTAssertFalse(error.message.contains("{"), "the message is a sentence, not the payload")
    }

    /// The gate is exact: a version this app was not written against is
    /// refused even when its body would happen to decode.
    func testASearchPayloadAtAnotherVersionIsRefusedToo() {
        let stdout = #"{"count":0,"file_count":0,"hits":[],"query":"x","rank_ms":0,"scan_ms":0,"schema_version":2}"#
        let result = RecallOutput.decode(
            RecallOutput.SearchResult.self,
            expectedVersion: RecallOutput.expectedSearchSchemaVersion,
            from: CommandResult(exitCode: 0, stdout: stdout, stderr: "")
        )
        guard case let .failure(error) = result else { return XCTFail("expected a version refusal") }
        XCTAssertEqual(error.message, "recall reported schema 2; Memory reads schema 1")
    }

    /// A refusal envelope still declares schema 1 and is still recall's own
    /// answer: it must read as the refusal, not as a version mismatch.
    func testARefusalEnvelopeIsNotMistakenForAVersionMismatch() {
        let result = RecallOutput.decode(
            RecallOutput.Today.self,
            expectedVersion: RecallOutput.expectedTodaySchemaVersion,
            from: CommandResult(
                exitCode: 1,
                stdout: #"{"error":"no memory repo at ~/notes","schema_version":1}"#,
                stderr: ""
            )
        )
        guard case let .failure(error) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(error, .refused("no memory repo at ~/notes"))
    }

    // MARK: - Refusals

    func testAJSONRefusalIsReportedInRecallsOwnWords() {
        let result = CommandResult(
            exitCode: 1,
            stdout: #"{"error":"no memory repo at ~/notes","schema_version":1}"#,
            stderr: ""
        )
        guard case let .failure(error) = RecallOutput.decode(RecallOutput.Today.self, expectedVersion: RecallOutput.expectedTodaySchemaVersion, from: result) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(error, .refused("no memory repo at ~/notes"))
        XCTAssertEqual(error.message, "no memory repo at ~/notes")
    }

    func testOutputThatIsNotJSONIsUnreadableRatherThanEmptyResults() {
        let result = CommandResult(exitCode: 0, stdout: "● 8 hits · 3,692 files\n", stderr: "")
        guard case let .failure(error) = RecallOutput.decode(RecallOutput.SearchResult.self, expectedVersion: RecallOutput.expectedSearchSchemaVersion, from: result) else {
            return XCTFail("expected a failure")
        }
        guard case .unreadable = error else { return XCTFail("expected unreadable, got \(error)") }
    }

    func testSilenceIsReportedWithWhateverWentToStandardError() {
        let result = CommandResult(exitCode: 1, stdout: "", stderr: "dyld: library not loaded\n")
        guard case let .failure(error) = RecallOutput.decode(RecallOutput.Today.self, expectedVersion: RecallOutput.expectedTodaySchemaVersion, from: result) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(error, .noOutput("dyld: library not loaded"))
    }

    // MARK: - Capture

    func testACaptureConfirmationIsTheSentenceAfterTheDot() {
        let outcome = RecallOutput.captureOutcome(from: CommandResult(
            exitCode: 0, stdout: Fixture.text("recall-capture-ok.txt"), stderr: ""
        ))
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.message, "appended to inbox/2026-09-03.md")
    }

    func testARefusedCaptureKeepsRecallsWordingAndIsNotOK() {
        let outcome = RecallOutput.captureOutcome(from: CommandResult(
            exitCode: 2, stdout: Fixture.text("recall-capture-refused.txt"), stderr: ""
        ))
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.message, "usage: recall capture <text>")
    }

    func testACaptureThatPrintsNothingStillSaysSomethingTrue() {
        let outcome = RecallOutput.captureOutcome(from: CommandResult(exitCode: 4, stdout: "", stderr: ""))
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.message, "recall failed (exit 4)")
    }
}
