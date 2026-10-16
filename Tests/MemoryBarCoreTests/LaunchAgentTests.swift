import XCTest
@testable import MemoryBarCore

/// The pause switch boots a real launchd job in and out of the user's domain,
/// so the argument arrays and the state reading are pinned against captured
/// `launchctl print` output and the collector's own plist.
final class LaunchAgentTests: XCTestCase {

    private let agent = LaunchAgent(
        label: "com.tristan.screenctx",
        plistPath: "/home/example/Library/LaunchAgents/com.tristan.screenctx.plist"
    )

    // MARK: - Commands

    func testTheServiceTargetIsTheUsersOwnGUIDomain() {
        XCTAssertEqual(agent.serviceTarget(uid: 501), "gui/501/com.tristan.screenctx")
        XCTAssertEqual(agent.domainTarget(uid: 501), "gui/501")
    }

    func testBootoutTakesTheServiceAndBootstrapTakesTheDomainAndFile() {
        // Getting these two the wrong way round is the classic launchctl
        // mistake: bootstrap needs the domain plus the plist on disk, bootout
        // needs the fully qualified service.
        XCTAssertEqual(
            agent.bootoutArguments(uid: 501),
            ["bootout", "gui/501/com.tristan.screenctx"]
        )
        XCTAssertEqual(
            agent.bootstrapArguments(uid: 501),
            ["bootstrap", "gui/501", "/home/example/Library/LaunchAgents/com.tristan.screenctx.plist"]
        )
        XCTAssertEqual(agent.printArguments(uid: 501), ["print", "gui/501/com.tristan.screenctx"])
    }

    func testEveryArgumentIsItsOwnElementSoNothingIsEverShellSyntax() {
        for argument in agent.bootstrapArguments(uid: 501) + agent.bootoutArguments(uid: 501) {
            XCTAssertFalse(argument.contains(" "), argument)
        }
    }

    // MARK: - State

    func testARunningJobReadsAsRunning() {
        let result = CommandResult(
            exitCode: 0, stdout: Fixture.text("launchctl-print-running.txt"), stderr: ""
        )
        XCTAssertEqual(LaunchAgent.parseState(result), .running)
        XCTAssertTrue(LaunchAgent.parseState(result).isBootstrapped)
    }

    func testAJobThatIsNotInTheDomainReadsAsPausedNotAsAnError() {
        // This is exactly what the pause switch produces, and launchctl exits
        // non-zero for it, so the text has to decide, not the exit code.
        let result = CommandResult(
            exitCode: 113, stdout: "", stderr: Fixture.text("launchctl-print-notloaded.txt")
        )
        XCTAssertEqual(LaunchAgent.parseState(result), .notLoaded)
        XCTAssertFalse(LaunchAgent.parseState(result).isBootstrapped)
    }

    func testABootstrappedButNotRunningJobIsStillBootstrapped() {
        let result = CommandResult(
            exitCode: 0,
            stdout: "gui/501/com.tristan.screenctx = {\n\tstate = waiting\n}\n",
            stderr: ""
        )
        XCTAssertEqual(LaunchAgent.parseState(result), .loaded("waiting"))
        XCTAssertTrue(LaunchAgent.parseState(result).isBootstrapped)
    }

    func testAnUnreadableAnswerIsUnknownAndNotTreatedAsRunning() {
        let result = CommandResult(exitCode: 1, stdout: "", stderr: "launchctl: unrecognised\n")
        guard case let .unknown(reason) = LaunchAgent.parseState(result) else {
            return XCTFail("expected unknown")
        }
        XCTAssertEqual(reason, "launchctl: unrecognised")
        XCTAssertFalse(LaunchAgent.parseState(result).isBootstrapped)
    }

    // MARK: - The plist

    func testTheCollectorPlistYieldsTheLogPathAndTheProgramItRuns() throws {
        let definition = try XCTUnwrap(
            LaunchAgent.parseDefinition(Fixture.data("com.tristan.screenctx.plist"))
        )

        XCTAssertEqual(definition.label, "com.tristan.screenctx")
        XCTAssertEqual(
            definition.programArguments,
            ["/home/example/.local/bin/screenctx", "collect"]
        )
        XCTAssertEqual(definition.logPath, "/home/example/Library/Logs/screenctx.log")
        XCTAssertTrue(definition.runAtLoad)
        XCTAssertTrue(definition.keepAlive)
    }

    func testSomethingThatIsNotAPlistIsNilRatherThanAnEmptyDefinition() {
        XCTAssertNil(LaunchAgent.parseDefinition(Data("not a plist".utf8)))
    }

    /// The collector writes its Screen Recording verdict with `stderrLine`,
    /// so when the two streams go to different files the log is stderr's.
    func testDivergedStreamsReadTheStderrFile() throws {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>Label</key><string>com.example.job</string>
            <key>StandardOutPath</key><string>/tmp/job.out</string>
            <key>StandardErrorPath</key><string>/tmp/job.err</string>
            </dict></plist>
            """
        let definition = try XCTUnwrap(LaunchAgent.parseDefinition(Data(plist.utf8)))
        XCTAssertEqual(definition.logPath, "/tmp/job.err")
    }

    func testAPlistWithNoLogPathsHasNoLogPath() throws {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>Label</key><string>com.example.job</string>
            </dict></plist>
            """
        let definition = try XCTUnwrap(LaunchAgent.parseDefinition(Data(plist.utf8)))
        XCTAssertNil(definition.logPath)
        XCTAssertFalse(definition.runAtLoad)
        XCTAssertEqual(definition.programArguments, [])
    }
}
