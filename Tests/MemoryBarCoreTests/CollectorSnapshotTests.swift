import XCTest
@testable import MemoryBarCore

/// The one place three sources become one word and one colour. The precedence
/// is the whole point, so each rung of it is pinned.
final class CollectorSnapshotTests: XCTestCase {

    private var collecting: ScreenctxStatus {
        ScreenctxStatus.parse(Fixture.text("screenctx-status-collecting.txt"))
    }

    func testACollectingJobIsGreenAndSaysWhatIsStoredAndWhenItLastTicked() {
        let snapshot = CollectorSnapshot.merge(
            status: collecting, launchState: .running, screenRecording: .granted
        )

        XCTAssertEqual(snapshot.health, .collecting)
        XCTAssertEqual(snapshot.headline, "Collecting · 1,168 frames")
        XCTAssertEqual(snapshot.context, "153.2 MB · last tick just now · Quick Launch")
        XCTAssertTrue(snapshot.isBootstrapped)
    }

    func testABootedOutJobReadsAsPausedEvenThoughItsStatusWouldSayStopped() {
        let stopped = ScreenctxStatus.parse(Fixture.text("screenctx-status-stopped.txt"))
        let snapshot = CollectorSnapshot.merge(
            status: stopped, launchState: .notLoaded, screenRecording: .granted
        )

        XCTAssertEqual(snapshot.health, .paused)
        XCTAssertEqual(snapshot.headline, "Paused")
        XCTAssertFalse(snapshot.isBootstrapped)
    }

    func testPauseOutranksAMissingGrantBecausePauseIsWhatTheUserJustDid() {
        let snapshot = CollectorSnapshot.merge(
            status: nil, launchState: .notLoaded, screenRecording: .missing
        )
        XCTAssertEqual(snapshot.health, .paused)
        XCTAssertEqual(snapshot.headline, "Paused")
    }

    func testAMissingAccessibilityGrantOutranksTheTickState() {
        let stopped = ScreenctxStatus.parse(Fixture.text("screenctx-status-stopped.txt"))
        let snapshot = CollectorSnapshot.merge(
            status: stopped, launchState: .running, screenRecording: .granted, accessibility: .missing
        )

        XCTAssertEqual(snapshot.health, .permission)
        XCTAssertEqual(snapshot.headline, "Accessibility missing")
    }

    /// `screenctx status` run by Memory reports Memory.app's own grant (TCC
    /// answers for the responsible process), so its `accessibility: NOT
    /// granted` says nothing about the collector and must not turn the dot red.
    func testTheStatusAccessibilityLineIsMemorysGrantAndIsNotTheCollectors() {
        let noStore = ScreenctxStatus.parse(Fixture.text("screenctx-status-no-store.txt"))
        XCTAssertEqual(noStore.accessibilityGranted, false)

        let unknown = CollectorSnapshot.merge(
            status: noStore, launchState: .running, screenRecording: .granted, accessibility: .unknown
        )
        XCTAssertNotEqual(unknown.headline, "Accessibility missing")
        XCTAssertEqual(unknown.health, .unknown)

        let collecting = CollectorSnapshot.merge(
            status: ScreenctxStatus.parse(Fixture.text("screenctx-status-collecting.txt").replacingOccurrences(
                of: "accessibility: granted", with: "accessibility: NOT granted"
            )),
            launchState: .running, screenRecording: .granted, accessibility: .granted
        )
        XCTAssertEqual(collecting.health, .collecting)
    }

    func testAMissingScreenRecordingGrantIsSaidOutLoud() {
        let snapshot = CollectorSnapshot.merge(
            status: collecting, launchState: .running, screenRecording: .missing
        )

        XCTAssertEqual(snapshot.health, .permission)
        XCTAssertEqual(snapshot.headline, "Screen Recording missing")
        XCTAssertTrue(snapshot.isBootstrapped)
    }

    func testAnUnknownScreenRecordingStateIsNotReportedAsMissing() {
        let snapshot = CollectorSnapshot.merge(
            status: collecting, launchState: .running, screenRecording: .unknown
        )
        XCTAssertEqual(snapshot.health, .collecting)
    }

    func testAStoppedButBootstrappedJobIsRedAndKeepsItsCounts() {
        let stopped = ScreenctxStatus.parse(Fixture.text("screenctx-status-stopped.txt"))
        let snapshot = CollectorSnapshot.merge(
            status: stopped, launchState: .running, screenRecording: .granted
        )

        XCTAssertEqual(snapshot.health, .stopped)
        XCTAssertEqual(snapshot.headline, "Stopped · 1,167 frames")
        XCTAssertEqual(snapshot.context, "153.0 MB · last tick 12m ago · Safari")
    }

    func testNoStoreYetIsDimNotRed() {
        let noStore = ScreenctxStatus(state: .noStore, accessibilityGranted: true, statusLine: "No store · run screenctx collect")
        let snapshot = CollectorSnapshot.merge(
            status: noStore, launchState: .running, screenRecording: .granted
        )

        XCTAssertEqual(snapshot.health, .unknown)
        XCTAssertEqual(snapshot.headline, "No store")
    }

    func testAMissingCollectorSaysSoInsteadOfShowingZeroes() {
        let snapshot = CollectorSnapshot.merge(
            status: nil, launchState: .notLoaded, screenRecording: .unknown, collectorInstalled: false
        )

        XCTAssertEqual(snapshot.health, .unknown)
        XCTAssertEqual(snapshot.headline, "Collector not installed")
        XCTAssertFalse(snapshot.isBootstrapped)
    }

    func testAnUnreadStatusOnALiveJobIsCheckingNotStopped() {
        let snapshot = CollectorSnapshot.merge(
            status: nil, launchState: .running, screenRecording: .granted
        )

        XCTAssertEqual(snapshot.health, .unknown)
        XCTAssertEqual(snapshot.headline, "Checking…")
        XCTAssertTrue(snapshot.isBootstrapped)
    }

    func testAnUnknownStatusWordIsShownAsScreenctxWroteIt() {
        let odd = ScreenctxStatus.parse("● Recovering index · 12 frames\n")
        let snapshot = CollectorSnapshot.merge(
            status: odd, launchState: .running, screenRecording: .granted
        )

        XCTAssertEqual(snapshot.health, .unknown)
        XCTAssertTrue(snapshot.headline.hasPrefix("Recovering index · 12 frames"), snapshot.headline)
    }
}
