import Foundation

/// A build or install step run as a launchd job rather than as a child of
/// Crest. macOS lets launchd's jobs run the throwaway binaries SwiftPM
/// compiles for package manifests, which it refuses to a GUI app's children
/// unless the app is listed under Developer Tools; and a job outlives Crest,
/// which the install step needs once it asks Crest to quit. The job is a
/// one-shot agent (`launchctl bootstrap` of a plist with KeepAlive off;
/// `launchctl submit` would restart it when it ends). Its output goes to a
/// log file that Crest follows; the Python helper ends its output with an
/// `::exit N` line.
@MainActor
final class BrowserSourceUpdateJob {
    // MARK: - Static Variables

    static let buildLabel = "com.manakkapoor.crest.source-update.build"
    static let installLabel = "com.manakkapoor.crest.source-update.install"
    static let buildLogURL = BrowserSourceUpdateProcess.logURL.deletingLastPathComponent()
        .appending(path: "source-update-build.log")

    // MARK: - Variables

    let label: String
    let log: URL

    private var isCancelled = false
    private var offset: UInt64 = 0
    private var partial = Data()

    // MARK: - Initializers

    init(label: String, log: URL) {
        self.label = label
        self.log = log
    }

    // MARK: - Actions - Submitting

    /// Starts `arguments` as a one-shot agent with the build tools on PATH,
    /// starting the log afresh. A finished job with the same label is booted
    /// out first; launchd keeps them loaded.
    func submit(_ arguments: [String], truncatingLog: Bool = true) throws {
        let manager = FileManager.default
        try? manager.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if truncatingLog || !manager.fileExists(atPath: log.path) {
            manager.createFile(atPath: log.path, contents: nil)
        }
        _ = Self.launchctl(["bootout", Self.domain + "/" + label])
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "EnvironmentVariables": ["PATH": BrowserSourceUpdateProcess.searchPath, "HOME": NSHomeDirectory()],
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Standard",
        ]
        let plistURL = Self.jobsDirectory.appending(path: label + ".plist")
        try manager.createDirectory(at: Self.jobsDirectory, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        let result = Self.launchctl(["bootstrap", Self.domain, plistURL.path])
        guard result.status == 0 else {
            throw BrowserSourceUpdateError.processFailed(
                "launchctl could not start the job: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Where the jobs' plists are written.
    static var jobsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Caches/Crest-local-release/jobs")
    }

    /// The person's GUI launchd domain.
    static var domain: String { "gui/\(getuid())" }

    /// Follows the log until the job prints its exit line or launchd reports
    /// it gone, giving `onLine` each other line as it appears. The exit
    /// status is nil when the job ended without saying, or was cancelled.
    func wait(onLine: @escaping @MainActor (String) -> Void) async -> Int32? {
        let status = await follow(onLine: onLine)
        if !isCancelled { finish() }
        return status
    }

    private func follow(onLine: @escaping @MainActor (String) -> Void) async -> Int32? {
        var ticks = 0
        while !isCancelled {
            for line in readNewLines() {
                if line.hasPrefix("::exit ") {
                    return Int32(line.dropFirst(7).trimmingCharacters(in: .whitespaces))
                }
                onLine(line)
            }
            ticks += 1
            if ticks % 6 == 0, let exitStatus = Self.finishedExitStatus(label: label) {
                for line in readNewLines() {
                    if line.hasPrefix("::exit ") {
                        return Int32(line.dropFirst(7).trimmingCharacters(in: .whitespaces))
                    }
                    onLine(line)
                }
                return exitStatus
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    func cancel() {
        isCancelled = true
        _ = Self.launchctl(["bootout", Self.domain + "/" + label])
    }

    /// Unloads the finished job so nothing restarts it and the label is free.
    func finish() {
        _ = Self.launchctl(["bootout", Self.domain + "/" + label])
    }

    // MARK: - Actions - Log

    private func readNewLines() -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else {
            return []
        }
        offset += UInt64(data.count)
        partial.append(data)
        var lines: [String] = []
        while let newline = partial.firstIndex(of: 0x0A) {
            lines.append(String(decoding: partial[partial.startIndex..<newline], as: UTF8.self))
            partial.removeSubrange(partial.startIndex...newline)
        }
        return lines
    }

    // MARK: - Actions - launchctl

    /// The wait status launchd recorded for a job that has ended, or nil
    /// while it runs; a job launchd no longer knows counts as ended.
    private static func finishedExitStatus(label: String) -> Int32? {
        let result = launchctl(["list", label])
        guard result.status == 0 else { return -1 }
        if result.output.contains("\"PID\" = ") { return nil }
        guard let range = result.output.range(of: "\"LastExitStatus\" = ") else { return -1 }
        let digits = result.output[range.upperBound...].prefix { $0.isNumber || $0 == "-" }
        let waitStatus = Int32(digits) ?? -1
        return waitStatus >= 0 ? waitStatus >> 8 : waitStatus
    }

    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
