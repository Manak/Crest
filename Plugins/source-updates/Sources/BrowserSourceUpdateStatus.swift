import Foundation

/// Where a personal build's Git checkout stands against upstream, as
/// `Personal/source-update.py status` reports it.
struct BrowserSourceUpdateStatus: Codable, Equatable, Sendable {
    // MARK: - Types

    struct Revision: Codable, Equatable, Sendable {
        let commit: String
        let version: String?
    }

    struct Upstream: Codable, Equatable, Sendable {
        let commit: String
        let version: String?
        /// Upstream commits the checkout does not have yet.
        let behind: Int
        /// Personal commits upstream does not have.
        let ahead: Int
    }

    /// The installed app's build, when the checkout still has its commit.
    struct Build: Codable, Equatable, Sendable {
        let commit: String?
        let version: String?
        /// Commits in the checkout that the installed app was built without,
        /// your own as much as upstream's merged in.
        let behind: Int
    }

    struct Engine: Codable, Equatable, Sendable {
        let localTag: String?
        let upstreamTag: String?
        let localChromium: String?
        let upstreamChromium: String?
        /// Whether upstream has published the engine its tree needs; nil when
        /// GitHub could not be reached.
        let upstreamPublished: Bool?
    }

    struct Note: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let category: String
        let message: String
    }

    /// Where the plugins would stand against upstream's tree: the ones the
    /// next build would leave out, and the hooks that no longer apply.
    struct Plugins: Codable, Equatable, Sendable {
        let hostVersion: String?
        let unavailable: [String]?
        let failingHooks: [String]?
        let error: String?

        var leavesPluginsOut: Bool { !(unavailable ?? []).isEmpty }

        /// One sentence for the offer, or nil when every plugin comes along.
        var summary: String? {
            if let error { return "The plugins could not be checked against upstream (\(error))." }
            guard leavesPluginsOut, let unavailable else { return nil }
            var text = "The update leaves out \(unavailable.joined(separator: ", "))"
            if let failingHooks, !failingHooks.isEmpty {
                let hooks = failingHooks.joined(separator: ", ")
                text +=
                    failingHooks.count == 1
                    ? ": the \(hooks) hook no longer applies"
                    : ": the \(hooks) hooks no longer apply"
            }
            return text + "."
        }
    }

    /// The one line the script prints when it cannot report.
    struct Failure: Codable, Sendable {
        let error: String
    }

    // MARK: - Variables

    let checkout: String
    let fetchError: String?
    let branch: String
    let dirty: Bool
    let local: Revision
    let upstream: Upstream
    let engine: Engine
    let build: Build?
    let notes: [Note]
    let commits: [String]
    /// Nil for a checkout without the plugin system.
    let plugins: Plugins?

    /// Commits the next build adds over the installed one: upstream's not yet
    /// merged, and the checkout's since the installed app was built.
    var changeCount: Int { upstream.behind + (build?.behind ?? 0) }

    var hasUpdate: Bool { changeCount > 0 }

    /// Whether the update changes the Chromium engine the app packages.
    var engineChanges: Bool { engine.localTag != engine.upstreamTag }

    var shortUpstreamCommit: String { String(upstream.commit.prefix(8)) }

    /// The commit the update builds: upstream's, once merged, or the
    /// checkout's own when upstream has nothing new.
    var targetCommit: String { upstream.behind > 0 ? upstream.commit : local.commit }

    var shortTargetCommit: String { String(targetCommit.prefix(8)) }

    var targetVersion: String? { upstream.behind > 0 ? upstream.version ?? local.version : local.version }

    /// The update's title, after the version it builds.
    var updateTitle: String {
        if let version = targetVersion { return "Crest \(version)" }
        return "Crest update"
    }

    /// What the update brings, in commits: upstream's since the build, your
    /// personal ones on top, or only the checkout's own since the build.
    var changeSummary: String {
        let own = build?.behind ?? 0
        if upstream.behind > 0 {
            var summary =
                "\(upstream.behind) upstream commit\(upstream.behind == 1 ? "" : "s") since your build, with your \(upstream.ahead) personal commit\(upstream.ahead == 1 ? "" : "s") kept on top."
            if own > 0 {
                summary += " Your checkout also has \(own) commit\(own == 1 ? "" : "s") since this build."
            }
            return summary
        }
        return "\(own) commit\(own == 1 ? "" : "s") in your checkout since this build, with nothing new upstream."
    }

    // MARK: - Actions - Text

    /// The Chromium engine's own line: what this build runs, what upstream
    /// now needs, and whether that engine can be downloaded yet.
    func engineSummary(buildEngine: String, installedChromium: String?) -> String {
        let installed = installedChromium ?? engine.localChromium ?? "unknown"
        let upstreamVersion = engine.upstreamChromium ?? "unknown"
        if buildEngine == "webkit" {
            return
                "This is a WebKit-only build with no Chromium engine. Upstream's engine is Chromium \(upstreamVersion)."
        }
        guard engineChanges else {
            return "Chromium engine \(installed) is current with upstream."
        }
        let change =
            installed == upstreamVersion
            ? "Upstream rebuilt its Chromium \(upstreamVersion) engine with changed host patches."
            : "Chromium engine update: \(installed) → \(upstreamVersion)."
        switch engine.upstreamPublished {
        case true?:
            return "\(change) Upstream has published the new engine; the update downloads it (about 165 MB)."
        case false?:
            return
                "\(change) Upstream has not published that engine yet, so the update will fail at the engine download until it does."
        case nil:
            return "\(change) GitHub could not be reached to check whether the new engine is published."
        }
    }

    /// Release notes for the offered update: upstream's own user-facing
    /// entries since this build, the engine line, and the commit subjects.
    func releaseNotesMarkdown(engineSummary: String) -> String {
        var lines: [String] = []
        let from =
            build?.version ?? build?.commit.map { String($0.prefix(8)) } ?? local.version
            ?? String(local.commit.prefix(8))
        let to = targetVersion ?? shortTargetCommit
        lines.append("## \(from) → \(to)")
        lines.append("")
        lines.append(changeSummary)
        lines.append("")
        lines.append("### Chromium engine")
        lines.append("")
        lines.append(engineSummary)
        for (category, heading) in [("new", "New"), ("improved", "Improved"), ("fixed", "Fixed")] {
            let entries = notes.filter { $0.category == category }
            guard !entries.isEmpty else { continue }
            lines.append("")
            lines.append("### \(heading)")
            lines.append("")
            lines.append(contentsOf: entries.map { "- \($0.message)" })
        }
        if !commits.isEmpty {
            lines.append("")
            lines.append("### Commits")
            lines.append("")
            lines.append(contentsOf: commits.map { "- \($0)" })
            if changeCount > commits.count {
                lines.append("- …and \(changeCount - commits.count) more")
            }
        }
        if let fetchError {
            lines.append("")
            lines.append("_Upstream could not be fetched (\(fetchError)); this compares against the last fetch._")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Actions - Parsing

    /// The status in the script's output: its last line is the JSON report,
    /// or an error object.
    static func parse(_ output: String) throws -> BrowserSourceUpdateStatus {
        guard
            let line = output.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("{") }),
            let data = line.data(using: .utf8)
        else {
            throw BrowserSourceUpdateError.unreadableStatus(
                output.split(separator: "\n").last.map(String.init) ?? "no output")
        }
        let decoder = JSONDecoder()
        if let failure = try? decoder.decode(Failure.self, from: data) {
            throw BrowserSourceUpdateError.statusFailed(failure.error)
        }
        return try decoder.decode(BrowserSourceUpdateStatus.self, from: data)
    }
}

enum BrowserSourceUpdateError: LocalizedError {
    case unreadableStatus(String)
    case statusFailed(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableStatus(let line): "The checkout status could not be read: \(line)"
        case .statusFailed(let message): message
        case .processFailed(let message): message
        }
    }
}
