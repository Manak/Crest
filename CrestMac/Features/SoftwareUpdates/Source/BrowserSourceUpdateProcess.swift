import Foundation

/// A command run from the personal build's checkout, with its output
/// delivered line by line on the main actor and appended to the update log.
@MainActor
final class BrowserSourceUpdateProcess {
    // MARK: - Static Variables

    /// Where the build tools live on this Mac: Homebrew's XcodeGen and
    /// Python, Xcode's command shims, and the .NET SDK the core needs.
    static let searchPath = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        NSHomeDirectory() + "/.dotnet",
    ].joined(separator: ":")

    static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: "Library/Logs/Crest/source-update.log")

    // MARK: - Variables

    private let process = Process()
    private let output = Pipe()

    // MARK: - Initializers

    init(executable: String, arguments: [String], directory: URL) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.searchPath
        environment["HOME"] = NSHomeDirectory()
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
    }

    /// `Personal/source-update.py` with `arguments`, from `checkout`.
    static func updateScript(_ arguments: [String], checkout: URL) -> BrowserSourceUpdateProcess {
        BrowserSourceUpdateProcess(
            executable: "/usr/bin/env",
            arguments: ["python3", "-I", checkout.appending(path: "Personal/source-update.py").path] + arguments,
            directory: checkout)
    }

    // MARK: - Actions - Running

    /// Runs the command to completion. Each output line reaches `onLine` as
    /// it arrives; the exit status comes back once the command ends.
    func run(onLine: @escaping @MainActor (String) -> Void) async throws -> Int32 {
        let log = Self.openLog()
        try process.run()
        for try await line in output.fileHandleForReading.bytes.lines {
            log?.write(Data((line + "\n").utf8))
            onLine(line)
        }
        // Output ends when the command exits; the wait that follows is brief.
        process.waitUntilExit()
        try? log?.close()
        return process.terminationStatus
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    // MARK: - Actions - Detached runs

    /// Starts `arguments` through the checkout's build script without waiting
    /// for it, writing to the update log instead of a pipe, so it survives
    /// Crest quitting: the install step asks Crest to quit and relaunches it.
    static func startDetached(buildScriptArguments arguments: [String], checkout: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [checkout.appending(path: "Personal/build-mac.sh").path] + arguments
        process.currentDirectoryURL = checkout
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        environment["HOME"] = NSHomeDirectory()
        process.environment = environment
        let log = openLog() ?? FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }

    private static func openLog() -> FileHandle? {
        let manager = FileManager.default
        try? manager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: logURL.path) {
            manager.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return nil }
        _ = try? handle.seekToEnd()
        let stamp = ISO8601DateFormatter().string(from: Date())
        handle.write(Data("\n[\(stamp)]\n".utf8))
        return handle
    }
}
