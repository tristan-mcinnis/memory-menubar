import XCTest
@testable import MemoryBarCore

/// Screen Recording is read from what the collector wrote about itself, so the
/// two sentences it can write are pinned against a real log tail.
final class CollectorLogTests: XCTestCase {

    func testTheLastVerdictInTheRealLogWins() {
        // The captured tail contains both verdicts, in order: the grant landed
        // partway through, so the answer is granted.
        let text = Fixture.text("screenctx-log-tail.txt")
        XCTAssertTrue(text.contains(CollectorLog.missingMarker))
        XCTAssertTrue(text.contains(CollectorLog.grantedMarker))
        XCTAssertEqual(CollectorLog.screenRecording(inLog: text), .granted)
    }

    func testABothWordingsOfTheDenialAreRead() {
        // screenctx has printed two spellings of the denial over its life; the
        // marker is the half both share.
        let old = "screenctx: Screen Recording NOT granted — text capture continues"
        let new = "screenctx: Screen Recording NOT granted (SCK probe failed) — frames/OCR wait"
        XCTAssertEqual(CollectorLog.screenRecording(inLog: old), .missing)
        XCTAssertEqual(CollectorLog.screenRecording(inLog: new), .missing)
    }

    func testADenialAfterAGrantIsTheAnswer() {
        let log = """
            screenctx: Screen Recording granted (SCK probe ok)
            screenctx collecting every 5s
            screenctx: Screen Recording NOT granted (SCK probe failed) — frames/OCR wait
            """
        XCTAssertEqual(CollectorLog.screenRecording(inLog: log), .missing)
    }

    func testALogWithNothingToSayIsUnknownAndNotAssumedGranted() {
        XCTAssertEqual(
            CollectorLog.screenRecording(inLog: "screenctx collecting every 5s\n"),
            .unknown
        )
        XCTAssertEqual(CollectorLog.screenRecording(inLog: ""), .unknown)
    }

    func testAMissingLogFileIsUnknown() {
        XCTAssertNil(CollectorLog.tail(ofFileAt: "/nonexistent/screenctx.log"))
        XCTAssertEqual(CollectorLog.verdicts(logPath: nil), .unknown)
        XCTAssertEqual(CollectorLog.verdicts(logPath: "/nonexistent/screenctx.log"), .unknown)
    }

    // MARK: - Accessibility

    func testTheRealLogEndsPastTheAccessibilityGate() {
        // The captured tail waits for Accessibility twice and gets past it
        // both times; the last launch is collecting.
        let text = Fixture.text("screenctx-log-tail.txt")
        XCTAssertTrue(text.contains(CollectorLog.accessibilityWaitMarker))
        XCTAssertEqual(CollectorLog.accessibility(inLog: text), .granted)
    }

    func testACollectorStillWaitingIsMissing() {
        let log = """
            screenctx: Screen Recording granted (SCK probe ok)
            screenctx collecting every 5s, ax-threshold 200, ocr on, frames on
            screenctx: waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)
            screenctx: waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)
            """
        XCTAssertEqual(CollectorLog.accessibility(inLog: log), .missing)
    }

    func testEitherScreenRecordingVerdictMeansTheGateWasPassed() {
        let waitedThenDenied = """
            screenctx: waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)
            screenctx: Screen Recording NOT granted (SCK probe failed) — frames/OCR wait
            """
        XCTAssertEqual(CollectorLog.accessibility(inLog: waitedThenDenied), .granted)
        XCTAssertEqual(CollectorLog.accessibility(inLog: ""), .unknown)
        XCTAssertEqual(CollectorLog.accessibility(inLog: "screenctx: cannot open store: x\n"), .unknown)
    }

    func testBothVerdictsComeFromOneReadOfTheFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memorybar-log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try "screenctx: waiting for Accessibility permission (System Settings)\n"
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            CollectorLog.verdicts(logPath: url.path),
            CollectorLog.Verdicts(screenRecording: .unknown, accessibility: .missing)
        )
    }

    func testOnlyTheTailIsReadSoAnOldLogCostsNoMoreThanAFreshOne() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memorybar-log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        var text = String(repeating: "screenctx: Screen Recording NOT granted (SCK probe failed)\n", count: 4_000)
        text += "screenctx: Screen Recording granted (SCK probe ok)\n"
        try text.write(to: url, atomically: true, encoding: .utf8)

        let tail = try XCTUnwrap(CollectorLog.tail(ofFileAt: url.path, bytes: 512))
        XCTAssertLessThanOrEqual(tail.utf8.count, 512)
        XCTAssertEqual(CollectorLog.screenRecording(inLog: tail), .granted)
    }
}
