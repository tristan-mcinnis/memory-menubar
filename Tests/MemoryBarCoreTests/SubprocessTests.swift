import XCTest
@testable import MemoryBarCore

/// `Subprocess.run` is the only place Memory builds a `Process`, and every
/// poll pays its cost twice (launchctl, then screenctx), so how soon it comes
/// back after the child exits is pinned here, alongside the timeout.
final class SubprocessTests: XCTestCase {

    /// The old `waitUntilExit()` on a dispatch worker never came back in under
    /// about 65 ms, even for a child that exits at once. The best of five runs
    /// is well under that now.
    func testReturnsPromptlyAfterTheChildExits() {
        var best = Double.infinity
        for _ in 0..<5 {
            let started = Date()
            let result = Subprocess.run(executable: "/bin/sh", arguments: ["-c", "echo ok; exit 3"])
            best = min(best, Date().timeIntervalSince(started))
            XCTAssertEqual(result.exitCode, 3)
            XCTAssertEqual(result.stdout, "ok\n")
        }
        XCTAssertLessThan(best, 0.04)
    }

    func testAWedgedChildIsCutOffAtTheTimeout() {
        let started = Date()
        let result = Subprocess.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertTrue(result.stderr.contains("timed out"), result.stderr)
    }

    func testNoColorIsAlwaysSet() {
        let result = Subprocess.run(executable: "/bin/sh", arguments: ["-c", "printf %s \"$NO_COLOR\""])
        XCTAssertEqual(result.stdout, "1")
    }
}
