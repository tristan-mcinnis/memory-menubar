import Foundation
import XCTest
@testable import MemoryBarCore

/// The house command contract (`design-system/docs/app-commands.md`) read back
/// off the bytes Memory writes, not off the types that wrote them.
///
/// Nothing here runs the real `recall` or touches the real `~/notes`: every
/// test writes into its own temporary directory and, where a CLI is needed,
/// points `ToolPaths` at a script that only records how it was called.
final class CommandManifestTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CommandManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// A stand-in for `recall`: executable, and never the real one.
    @discardableResult
    private func makeFakeRecall(named name: String = "recall", recordingTo log: URL? = nil) throws -> String {
        let path = directory.appendingPathComponent(name).path
        let script: String
        if let log {
            script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(log.path)'\necho '● captured'\n"
        } else {
            script = "#!/bin/sh\nexit 0\n"
        }
        XCTAssertTrue(FileManager.default.createFile(
            atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755]
        ))
        return path
    }

    /// A path nothing is installed at.
    private var missingRecall: String { directory.appendingPathComponent("not-installed").path }

    private func tools(recall: String) -> ToolPaths {
        ToolPaths(screenctx: missingRecall, recall: recall)
    }

    /// The manifest as JSON objects, which is what a reader sees.
    private func manifestObject(_ document: CommandManifest.Document) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The manifest document

    func testTheManifestCarriesEveryFieldTheContractNames() throws {
        let recall = try makeFakeRecall()
        let document = try XCTUnwrap(CommandManifest.document(
            tools: tools(recall: recall), environment: [:], directory: directory
        ))
        let object = try manifestObject(document)

        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["app"] as? String, "memory")
        XCTAssertEqual(object["name"] as? String, "Memory")
        XCTAssertEqual(object["transport"] as? String, "exec")
        XCTAssertEqual(object["endpoint"] as? String, recall)
        XCTAssertEqual(object["status"] as? String, directory.appendingPathComponent("memory.status.json").path)
        XCTAssertNotNil(object["commands"] as? [[String: Any]])
    }

    func testTheFourCommandsAreCaptureAndRead() throws {
        let document = try XCTUnwrap(CommandManifest.document(
            tools: tools(recall: try makeFakeRecall()), environment: [:], directory: directory
        ))
        let commands = try XCTUnwrap(try manifestObject(document)["commands"] as? [[String: Any]])

        XCTAssertEqual(commands.map { $0["id"] as? String }, [
            "memory.capture", "memory.search", "memory.today", "memory.tasks",
        ])
        XCTAssertEqual(commands.map { $0["title"] as? String }, [
            "Capture a Thought", "Search Memory", "Today", "Open Tasks",
        ])
        XCTAssertEqual(commands.map { $0["verb"] as? String }, ["capture", "search", "today", "tasks"])
    }

    /// The tasks command is a read: it lists open tasks and takes no argument.
    func testTheTasksCommandReadsOpenTasks() throws {
        let document = try XCTUnwrap(CommandManifest.document(
            tools: tools(recall: try makeFakeRecall()), environment: [:], directory: directory
        ))
        let commands = try XCTUnwrap(try manifestObject(document)["commands"] as? [[String: Any]])
        let tasks = try XCTUnwrap(commands.first { $0["id"] as? String == "memory.tasks" })

        XCTAssertEqual(tasks["title"] as? String, "Open Tasks")
        XCTAssertEqual(tasks["verb"] as? String, "tasks")
        XCTAssertTrue(tasks["needs"] is NSNull, "tasks takes no argument")
        XCTAssertNotNil(tasks.index(forKey: "needs"))
    }

    /// Nothing published may delete or rewrite a memory. The verbs are the
    /// four read-and-capture ones and no others.
    func testNoPublishedCommandCanDestroyAMemory() throws {
        let document = try XCTUnwrap(CommandManifest.document(
            tools: tools(recall: try makeFakeRecall()), environment: [:], directory: directory
        ))
        let verbs = Set(document.commands.map(\.verb))
        XCTAssertEqual(verbs, ["capture", "search", "today", "tasks"])
        XCTAssertFalse(verbs.contains("remember"), "remember is recall's hidden alias, not a published verb")
        for forbidden in ["forget", "delete", "rm", "clear", "edit", "rewrite", "prune"] {
            XCTAssertFalse(verbs.contains(forbidden), forbidden)
        }
    }

    /// `needs` is written even when the command takes no argument: a reader
    /// switches on the key, and an omitted one reads as a missing field.
    func testNeedsIsWrittenAsNullForTheCommandsThatTakeNoArgument() throws {
        let document = try XCTUnwrap(CommandManifest.document(
            tools: tools(recall: try makeFakeRecall()), environment: [:], directory: directory
        ))
        let commands = try XCTUnwrap(try manifestObject(document)["commands"] as? [[String: Any]])

        XCTAssertEqual(commands[0]["needs"] as? String, "text")
        XCTAssertEqual(commands[1]["needs"] as? String, "text")
        XCTAssertTrue(commands[2]["needs"] is NSNull, "today must carry an explicit null")
        XCTAssertNotNil(commands[2].index(forKey: "needs"))
        XCTAssertTrue(commands[3]["needs"] is NSNull, "tasks must carry an explicit null")
        XCTAssertNotNil(commands[3].index(forKey: "needs"))
    }

    // MARK: - Endpoint resolution

    func testTheConfiguredPathWinsWhenItIsThere() throws {
        let recall = try makeFakeRecall()
        XCTAssertEqual(
            CommandManifest.resolveEndpoint(tools: tools(recall: recall), environment: [:]),
            recall
        )
    }

    func testPathIsSearchedWhenTheConfiguredPathIsNotThere() throws {
        let onPath = try makeFakeRecall()
        let resolved = CommandManifest.resolveEndpoint(
            tools: tools(recall: missingRecall),
            environment: ["PATH": "/nowhere-at-all:\(directory.path)"]
        )
        XCTAssertEqual(resolved, onPath)
    }

    func testAMissingBinaryResolvesToNothing() {
        XCTAssertNil(CommandManifest.resolveEndpoint(
            tools: tools(recall: missingRecall), environment: ["PATH": "/nowhere-at-all"]
        ))
    }

    func testNoManifestIsWrittenWhenRecallIsNotInstalled() {
        let outcome = CommandManifest.publish(
            tools: tools(recall: missingRecall), environment: ["PATH": "/nowhere-at-all"], directory: directory
        )
        guard case let .skipped(reason) = outcome else {
            return XCTFail("expected a skip, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("recall"), reason)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: CommandManifest.manifestURL(in: directory).path
        ))
    }

    /// A file that cannot be written is a log line, never a throw at the app.
    func testAFailedWriteIsReportedAndNotThrown() throws {
        let blocked = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let outcome = CommandManifest.publish(
            tools: tools(recall: try makeFakeRecall()),
            environment: [:],
            directory: blocked.appendingPathComponent("commands", isDirectory: true)
        )
        guard case .failed = outcome else { return XCTFail("expected a failure, got \(outcome)") }
    }

    // MARK: - Writing

    func testPublishWritesTheManifestWhereTheContractSaysAndRepeatsItself() throws {
        let recall = try makeFakeRecall()
        let outcome = CommandManifest.publish(
            tools: tools(recall: recall), environment: [:], directory: directory
        )
        let url = CommandManifest.manifestURL(in: directory)
        XCTAssertEqual(outcome, .wrote(url.path))
        XCTAssertEqual(url.lastPathComponent, "memory.json")

        let first = try Data(contentsOf: url)
        XCTAssertEqual(first.last, 0x0A, "the file ends in a newline")
        _ = CommandManifest.publish(tools: tools(recall: recall), environment: [:], directory: directory)
        XCTAssertEqual(try Data(contentsOf: url), first, "the same state writes the same bytes")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: first) as? [String: Any]
        )
        XCTAssertEqual(object["app"] as? String, "memory")
        XCTAssertEqual(object["endpoint"] as? String, recall)
    }

    func testTheDirectoryIsTheOneTheContractNames() throws {
        let support = URL(fileURLWithPath: "/Somewhere/Library/Application Support")
        let directory = try XCTUnwrap(CommandManifest.directory(applicationSupport: support))
        XCTAssertEqual(directory.path, "/Somewhere/Library/Application Support/House/commands")
        XCTAssertEqual(CommandManifest.manifestURL(in: directory).lastPathComponent, "memory.json")
        XCTAssertEqual(CommandManifest.statusURL(in: directory).lastPathComponent, "memory.status.json")
    }

    // MARK: - Status

    func testTheStatusDocumentHasTheShapeEveryHouseAppAnswers() throws {
        let recall = try makeFakeRecall()
        let outcome = CommandManifest.publishStatus(
            headline: "Collecting · 412 frames",
            tools: tools(recall: recall),
            environment: [:],
            directory: directory
        )
        XCTAssertEqual(outcome, .wrote(CommandManifest.statusURL(in: directory).path))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Data(contentsOf: CommandManifest.statusURL(in: directory))
        ) as? [String: Any])
        XCTAssertEqual(object["app"] as? String, "memory")
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["busy"] as? Bool, false)
        XCTAssertEqual(object["detail"] as? String, "Collecting · 412 frames")
    }

    /// `detail` is the panel's own headline, word for word. Memory never
    /// re-spells a state for a second audience.
    func testDetailIsTheHeadlineVerbatim() throws {
        for headline in ["Checking…", "Paused", "Screen Recording missing"] {
            let status = CommandManifest.status(headline: headline, endpoint: try makeFakeRecall())
            XCTAssertEqual(status.detail, headline)
            XCTAssertFalse(status.busy)
        }
    }

    func testStatusIsNotOkWhenTheEndpointIsGone() {
        XCTAssertFalse(CommandManifest.status(headline: "Paused", endpoint: missingRecall).ok)
        XCTAssertFalse(CommandManifest.status(headline: "Paused", endpoint: nil).ok)
    }

    // MARK: - How the arguments reach the CLI

    /// The published commands run through the one process lane, which takes an
    /// executable path and an argument array. A thought with a quote, a
    /// semicolon and a command substitution in it arrives as one argument and
    /// is never syntax.
    func testAnArgumentWithShellCharactersArrivesAsOneArgument() throws {
        let log = directory.appendingPathComponent("argv.txt")
        let recall = try makeFakeRecall(recordingTo: log)
        let thought = "ship it; rm -rf ~ \"quoted\" $(whoami) `date` & | > /dev/null"

        let outcome = RecallOutput.capture(thought, tools: tools(recall: recall))
        XCTAssertTrue(outcome.ok)

        let argv = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
        XCTAssertEqual(argv, ["capture", thought])
    }

    func testEveryPublishedVerbIsTheFirstArgumentAndNothingIsJoined() throws {
        let log = directory.appendingPathComponent("argv.txt")
        let recall = try makeFakeRecall(recordingTo: log)

        _ = RecallOutput.search("design system; ls", tools: tools(recall: recall))
        var argv = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        XCTAssertEqual(argv, ["search", "design system; ls", "--json"])

        _ = RecallOutput.today(tools: tools(recall: recall))
        argv = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        XCTAssertEqual(argv, ["today", "--json"])
    }
}
