import XCTest
@testable import MemoryBarCore

/// The panel header is only as honest as this parser. Every case here runs
/// against captured `screenctx status` output.
final class ScreenctxStatusTests: XCTestCase {

    func testLiveCollectingStatusReadsEveryPartOfTheStatusLine() {
        let status = ScreenctxStatus.parse(Fixture.text("screenctx-status-collecting.txt"))

        XCTAssertEqual(status.state, .collecting)
        XCTAssertEqual(status.framesText, "1,168 frames")
        XCTAssertEqual(status.sizeText, "153.2 MB")
        XCTAssertEqual(status.tickText, "last tick just now")
        XCTAssertEqual(status.frontApp, "Quick Launch")
    }

    func testLiveStatusReadsThePermissionAndStoreBlocks() {
        let status = ScreenctxStatus.parse(Fixture.text("screenctx-status-collecting.txt"))

        XCTAssertEqual(status.accessibilityGranted, true)
        XCTAssertEqual(status.storePath, "/home/example/Library/Application Support/screenctx/context.sqlite3")
        XCTAssertEqual(status.schema, "v3")
        XCTAssertEqual(status.databaseSize, "60.3 MB")
    }

    func testStoppedStatusKeepsItsOwnWords() {
        let status = ScreenctxStatus.parse(Fixture.text("screenctx-status-stopped.txt"))

        XCTAssertEqual(status.state, .stopped)
        XCTAssertEqual(status.tickText, "last tick 12m ago")
        XCTAssertEqual(status.frontApp, "Safari")
        XCTAssertEqual(status.framesText, "1,167 frames")
    }

    func testNoStoreStatusHasNoCountsAndSaysAccessibilityIsMissing() {
        let status = ScreenctxStatus.parse(Fixture.text("screenctx-status-no-store.txt"))

        XCTAssertEqual(status.state, .noStore)
        XCTAssertNil(status.framesText)
        XCTAssertNil(status.sizeText)
        XCTAssertEqual(status.accessibilityGranted, false)
        // The store line carries a trailing note; the path stops before it.
        XCTAssertEqual(status.storePath, "/home/example/Library/Application Support/screenctx/context.sqlite3")
        XCTAssertNil(status.schema)
    }

    func testNoTicksYetIsATickTextNotAFrontApp() {
        let status = ScreenctxStatus.parse(Fixture.text("screenctx-status-no-ticks.txt"))

        XCTAssertEqual(status.tickText, "no ticks yet")
        XCTAssertNil(status.frontApp)
        XCTAssertEqual(status.framesText, "0 frames")
    }

    func testAnUnknownFirstWordIsNotGuessedAtAndTheLineIsKept() {
        let status = ScreenctxStatus.parse("● Something new · 4 frames\n")

        XCTAssertEqual(status.state, .unknown)
        XCTAssertEqual(status.statusLine, "Something new · 4 frames")
        XCTAssertEqual(status.framesText, "4 frames")
    }

    func testEmptyOutputParsesToAnEmptyStatusRatherThanCrashing() {
        let status = ScreenctxStatus.parse("")

        XCTAssertEqual(status.state, .unknown)
        XCTAssertNil(status.accessibilityGranted)
        XCTAssertEqual(status.statusLine, "")
    }

    func testTheStatusLineIsTheOneLineWithoutAColon() {
        // The house rule screenctx follows: the status line has no colon, the
        // key and value lines all do. The parser leans on exactly that, so it
        // is pinned here.
        let text = Fixture.text("screenctx-status-collecting.txt")
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertTrue(first.hasPrefix("●"))
        XCTAssertFalse(first.contains(":"))
    }

    func testSingularFrameCountIsStillReadAsFrames() {
        let status = ScreenctxStatus.parse("● Collecting · 1 frame · 0.1 MB · last tick 3s ago · Mail\n")

        XCTAssertEqual(status.framesText, "1 frame")
        XCTAssertEqual(status.frontApp, "Mail")
    }

    func testKeyValueSplitsOnTheFirstColonOnly() {
        let pair = ScreenctxStatus.keyValue("last tick:     2026-09-03 18:31:25  blackout  Quick Launch")

        XCTAssertEqual(pair?.key, "last tick")
        XCTAssertEqual(pair?.value, "2026-09-03 18:31:25  blackout  Quick Launch")
    }

    func testALineWithNoColonIsNotAKeyValueLine() {
        XCTAssertNil(ScreenctxStatus.keyValue("ACTIVITY"))
    }
}
