import Foundation

/// The result of one command: its exit status and both streams as text.
public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// The one place in Memory a `Process` is built.
///
/// Every call passes an executable path and an argument array. Nothing is ever
/// handed to a shell, so a file name with a space, a quote, or a semicolon in
/// it is an argument and can never become syntax. Callers run this off the
/// main thread; the panel never blocks on a subprocess.
public enum Subprocess {

    /// Run `executable` with `arguments` and wait for it.
    ///
    /// `NO_COLOR` is always set: every house CLI drops its ANSI escapes when it
    /// sees it, so what comes back is the plain words a parser can read.
    /// A command that outlives `timeout` is terminated and reported as a
    /// failure, so a wedged CLI cannot pin a polling task forever.
    public static func run(
        executable: String,
        arguments: [String],
        environment extra: [String: String] = [:],
        timeout: TimeInterval = 30
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        for (key, value) in extra { environment[key] = value }
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        // Exit is signalled, not polled. `waitUntilExit()` spins the calling
        // thread's run loop, and a dispatch worker has none running, so it
        // came back about 65 ms after the child had already gone, on every
        // spawn of every poll (measured 2026-09-26). Set before `run()` so a
        // child that exits at once cannot be missed.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: "\(executable): \(error.localizedDescription)")
        }

        // Read both pipes on their own threads. A command that fills the 64 KB
        // pipe buffer while we wait for it to exit would deadlock
        // otherwise, and `screenctx status` on a long tick-outcome line is
        // closer to that limit than it looks.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        for (pipe, sink) in [(out, { outData = $0 }), (err, { errData = $0 })] as [(Pipe, (Data) -> Void)] {
            DispatchQueue.global(qos: .utility).async(group: group) {
                sink(pipe.fileHandleForReading.readDataToEndOfFile())
            }
        }

        let finished = exited.wait(timeout: .now() + timeout) == .success
        if !finished {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
            return CommandResult(exitCode: -1, stdout: "", stderr: "\(executable): timed out after \(Int(timeout))s")
        }
        _ = group.wait(timeout: .now() + 5)

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}

/// Where Memory finds the programs it drives. Defaults are the installed
/// paths; tests and the settings pane substitute their own.
public struct ToolPaths: Equatable, Sendable {
    public var screenctx: String
    public var recall: String
    public var launchctl: String
    public var open: String

    public init(
        screenctx: String = NSHomeDirectory() + "/.local/bin/screenctx",
        recall: String = NSHomeDirectory() + "/.local/bin/recall",
        launchctl: String = "/bin/launchctl",
        open: String = "/usr/bin/open"
    ) {
        self.screenctx = screenctx
        self.recall = recall
        self.launchctl = launchctl
        self.open = open
    }

    public static let installed = ToolPaths()

    public func exists(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}
