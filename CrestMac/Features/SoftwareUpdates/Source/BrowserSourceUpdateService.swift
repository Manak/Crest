import Foundation
import Observation

/// Software updates for a personal build made from a Git checkout: upstream
/// is fetched and compared, the update is merged into the personal branch
/// and built from source while Crest keeps running, and the staged app
/// replaces this one on relaunch. It drives the same model, sidebar card and
/// settings rows as the Sparkle updater the official app uses.
@MainActor
@Observable
final class BrowserSourceUpdateService {
    // MARK: - Types

    /// What the build recorded about its origin in Info.plist.
    struct Configuration: Equatable, Sendable {
        let checkout: URL
        let commit: String
        /// "chromium" or "webkit": the composition the build script made.
        let engine: String
        let installedChromiumVersion: String?

        var shortCommit: String { String(commit.prefix(8)) }

        /// The configuration of a build that knows its checkout, which still
        /// has the update script; nil for any other build.
        static func current(bundle: Bundle = .main) -> Configuration? {
            guard
                let path = bundle.object(forInfoDictionaryKey: "CrestSourceCheckout") as? String, !path.isEmpty,
                let commit = bundle.object(forInfoDictionaryKey: "CrestSourceCommit") as? String, !commit.isEmpty
            else { return nil }
            let checkout = URL(fileURLWithPath: path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: checkout.appending(path: "Personal/source-update.py").path)
            else { return nil }
            return Configuration(
                checkout: checkout,
                commit: commit,
                engine: bundle.object(forInfoDictionaryKey: "CrestSourceEngine") as? String ?? "chromium",
                installedChromiumVersion: bundle.object(forInfoDictionaryKey: "CrestChromiumEngineVersion") as? String)
        }
    }

    /// An update built and waiting to be installed on relaunch.
    struct StagedUpdate: Equatable, Sendable {
        let commit: String
        let version: String?
        let path: URL
    }

    // MARK: - Static Variables

    static let automaticChecksKey = "crest.source-update.automatic-checks"
    static let automaticBuildsKey = "crest.source-update.automatic-builds"
    static let skippedCommitKey = "crest.source-update.skipped-commit"
    static let pendingInstallCommitKey = "crest.source-update.pending-install-commit"
    static let lastCheckKey = "crest.source-update.last-check"
    static let minimumAutomaticCheckInterval: TimeInterval = 60 * 60
    static let upstreamRepository = "pauljoda/Crest"

    // MARK: - Variables

    let configuration: Configuration
    let model: BrowserSoftwareUpdateModel

    private(set) var status: BrowserSourceUpdateStatus?
    private(set) var statusError: String?
    private(set) var lastCheckDate: Date?
    private(set) var isChecking = false
    private(set) var isBuilding = false
    private(set) var stagedUpdate: StagedUpdate?

    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var checkProcess: BrowserSourceUpdateProcess?
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var buildJob: BrowserSourceUpdateJob?
    @ObservationIgnored private var buildWasCancelled = false

    var automaticallyChecksForUpdates: Bool {
        preferences.object(forKey: Self.automaticChecksKey) == nil
            || preferences.bool(forKey: Self.automaticChecksKey)
    }

    var automaticallyBuildsUpdates: Bool {
        preferences.bool(forKey: Self.automaticBuildsKey)
    }

    /// The Chromium engine's line for Settings, before and after a check.
    var engineSummary: String {
        if let status {
            return status.engineSummary(
                buildEngine: configuration.engine, installedChromium: configuration.installedChromiumVersion)
        }
        if configuration.engine == "webkit" {
            return "This is a WebKit-only build with no Chromium engine."
        }
        if let installed = configuration.installedChromiumVersion {
            return "Chromium engine \(installed). Check for updates to compare it with upstream."
        }
        return "Check for updates to compare the engine with upstream."
    }

    /// How updates reach this build, for the settings footer.
    var guidance: String {
        var text =
            "Updates come from the Git checkout at \(configuration.checkout.path): \(Self.upstreamRepository) is merged into your mine branch, built, and installed when Crest relaunches. This build is commit \(configuration.shortCommit)."
        if let lastCheckDate {
            text += " Last checked \(lastCheckDate.formatted(date: .abbreviated, time: .shortened))."
        }
        if let statusError {
            text += " \(statusError)"
        }
        return text
    }

    private var stagingDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Caches/Crest-local-release/staged")
    }

    // MARK: - Initializers

    init(configuration: Configuration, model: BrowserSoftwareUpdateModel, preferences: UserDefaults) {
        self.configuration = configuration
        self.model = model
        self.preferences = preferences
    }

    // MARK: - Actions - Launch

    func start() {
        lastCheckDate = preferences.object(forKey: Self.lastCheckKey) as? Date
        if let pending = preferences.string(forKey: Self.pendingInstallCommitKey) {
            preferences.removeObject(forKey: Self.pendingInstallCommitKey)
            if pending == configuration.commit {
                model.presentInstalled(relaunched: true, acknowledgement: {})
            }
        }
        // A staged build from an earlier session is stale once this one runs.
        try? FileManager.default.removeItem(at: stagingDirectory)
        guard automaticallyChecksForUpdates else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.checkAutomaticallyIfDue()
        }
    }

    func applicationDidBecomeActive() {
        checkAutomaticallyIfDue()
    }

    private func checkAutomaticallyIfDue(now: Date = Date()) {
        guard automaticallyChecksForUpdates, model.phase == .idle else { return }
        if let lastCheckDate, now.timeIntervalSince(lastCheckDate) < Self.minimumAutomaticCheckInterval {
            return
        }
        startCheck(userInitiated: false)
    }

    // MARK: - Actions - Checking

    /// A check the person asked for, shown as it runs.
    func checkForUpdates() {
        preferences.removeObject(forKey: Self.skippedCommitKey)
        startCheck(userInitiated: true)
    }

    private func startCheck(userInitiated: Bool) {
        guard checkTask == nil, buildTask == nil else { return }
        if userInitiated {
            model.presentChecking(cancellation: { [weak self] in
                self?.checkProcess?.terminate()
                self?.checkTask?.cancel()
            })
        }
        checkTask = Task { [weak self] in
            await self?.performCheck(userInitiated: userInitiated)
            self?.checkTask = nil
            self?.checkProcess = nil
        }
    }

    private func performCheck(userInitiated: Bool) async {
        isChecking = true
        defer { isChecking = false }
        let process = BrowserSourceUpdateProcess.updateScript(
            ["status", "--installed", configuration.commit], checkout: configuration.checkout)
        checkProcess = process
        var output = ""
        let result: Result<BrowserSourceUpdateStatus, any Error>
        do {
            let code = try await process.run { line in output += line + "\n" }
            if Task.isCancelled { return }
            if code != 0, !output.contains("{") {
                throw BrowserSourceUpdateError.processFailed(Self.lastMeaningfulLine(of: output) ?? "exit \(code)")
            }
            result = .success(try BrowserSourceUpdateStatus.parse(output))
        } catch {
            if Task.isCancelled { return }
            result = .failure(error)
        }
        let now = Date()
        lastCheckDate = now
        preferences.set(now, forKey: Self.lastCheckKey)
        switch result {
        case .failure(let error):
            statusError = error.localizedDescription
            if userInitiated {
                model.presentError(
                    message: "Crest could not check the checkout for updates: \(error.localizedDescription)",
                    acknowledgement: {})
            }
        case .success(let status):
            statusError = nil
            self.status = status
            if status.hasUpdate {
                if !userInitiated, preferences.string(forKey: Self.skippedCommitKey) == status.targetCommit {
                    return
                }
                offer(status)
                if !userInitiated, automaticallyBuildsUpdates {
                    model.installPresentedUpdate()
                }
            } else if userInitiated {
                var message = "Crest is up to date with upstream at commit \(status.shortUpstreamCommit)."
                if status.upstream.ahead > 0 {
                    let ahead = status.upstream.ahead
                    message += " Your \(ahead) personal commit\(ahead == 1 ? "" : "s") are on top."
                }
                message += " \(engineSummary)"
                if let fetchError = status.fetchError {
                    message += " Upstream could not be fetched (\(fetchError))."
                }
                model.presentNoUpdate(message: message, acknowledgement: {})
            }
        }
    }

    private func offer(_ status: BrowserSourceUpdateStatus) {
        let engineLine = engineSummary
        var message =
            status.upstream.behind > 0
            ? "\(status.changeSummary) Installing merges upstream into your branch and rebuilds Crest."
            : "\(status.changeSummary) Installing rebuilds Crest."
        if status.engineChanges {
            message += " \(engineLine)"
        }
        if status.dirty {
            message += " The checkout has uncommitted changes; commit or stash them first."
        }
        model.presentUpdate(
            title: status.updateTitle,
            version: status.targetVersion,
            build: status.shortTargetCommit,
            releaseNotes: status.releaseNotesMarkdown(engineSummary: engineLine),
            informationURL: status.upstream.behind > 0
                ? URL(
                    string:
                        "https://github.com/\(Self.upstreamRepository)/compare/\(status.local.commit.prefix(12))...\(status.upstream.commit.prefix(12))"
                )
                : nil,
            message: message,
            isInformationOnly: false,
            allowsOfferRefresh: false,
            install: { [weak self] in self?.beginBuild(for: status) },
            skip: { [weak self] in
                self?.preferences.set(status.targetCommit, forKey: Self.skippedCommitKey)
            })
    }

    // MARK: - Actions - Building

    private func beginBuild(for status: BrowserSourceUpdateStatus) {
        guard buildTask == nil else { return }
        buildWasCancelled = false
        let stagePath = stagingDirectory.appending(path: "Crest.app")
        var arguments = [
            "python3", "-I", configuration.checkout.appending(path: "Personal/source-update.py").path,
            "prepare", "--stage", stagePath.path,
        ]
        if configuration.engine == "webkit" { arguments.append("--webkit") }
        let job = BrowserSourceUpdateJob(
            label: BrowserSourceUpdateJob.buildLabel, log: BrowserSourceUpdateJob.buildLogURL)
        do {
            try job.submit(arguments)
        } catch {
            model.presentError(
                message: "The update could not be started: \(error.localizedDescription)", acknowledgement: {})
            return
        }
        buildJob = job
        isBuilding = true
        model.presentSourceBuild(
            message: "Merging upstream changes…",
            cancellation: { [weak self] in
                guard let self else { return }
                buildWasCancelled = true
                buildJob?.cancel()
            })
        buildTask = Task { [weak self] in
            guard let self else { return }
            var recent: [String] = []
            let code = await job.wait { [weak self] line in
                recent.append(line)
                if recent.count > 80 { recent.removeFirst() }
                if line.hasPrefix("==> ") {
                    self?.model.setSourceBuildMessage(String(line.dropFirst(4)) + "…")
                }
            }
            buildTask = nil
            buildJob = nil
            isBuilding = false
            guard !buildWasCancelled else { return }
            if code == 0 {
                let staged = StagedUpdate(
                    commit: Self.recordedCommit(of: stagePath) ?? status.upstream.commit,
                    version: status.upstream.version, path: stagePath)
                stagedUpdate = staged
                model.presentAutomaticUpdateReady(
                    title: status.updateTitle,
                    version: status.upstream.version,
                    build: status.shortUpstreamCommit,
                    releaseNotes: status.releaseNotesMarkdown(engineSummary: engineSummary),
                    informationURL: nil,
                    message: "The update is built. Relaunch to finish installing it.",
                    installAndRelaunch: { [weak self] in self?.installStaged() })
            } else {
                model.presentError(message: Self.failureMessage(code: code ?? -1, recent: recent), acknowledgement: {})
            }
        }
    }

    /// Asks a launchd job to quit Crest, install the staged app and open it.
    /// A job outlives Crest, so Crest's quit does not end it.
    func installStaged() {
        guard let stagedUpdate else { return }
        preferences.set(stagedUpdate.commit, forKey: Self.pendingInstallCommitKey)
        let job = BrowserSourceUpdateJob(
            label: BrowserSourceUpdateJob.installLabel, log: BrowserSourceUpdateProcess.logURL)
        do {
            try job.submit(
                [
                    "/bin/zsh", configuration.checkout.appending(path: "Personal/build-mac.sh").path,
                    "--install-staged", stagedUpdate.path.path,
                ], truncatingLog: false)
        } catch {
            preferences.removeObject(forKey: Self.pendingInstallCommitKey)
            model.presentError(
                message: "The staged update could not be installed: \(error.localizedDescription)", acknowledgement: {})
        }
    }

    /// The commit a staged app records, which the relaunched app compares
    /// against its own to know the install went through.
    private static func recordedCommit(of app: URL) -> String? {
        guard
            let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CrestSourceCommit"] as? String
    }

    private static func failureMessage(code: Int32, recent: [String]) -> String {
        if code == 3 {
            let detail = recent.last(where: { $0.contains("conflict") }) ?? ""
            return
                "Upstream changes conflict with your personal commits. \(detail) Resolve the merge in the checkout, then check for updates again."
        }
        if let line = recent.last(where: { $0.contains("No Chromium engine is published") }) {
            return line
        }
        if recent.contains(where: { $0.contains("manifest compilation") }) {
            return
                "Xcode could not run Swift Package Manager's manifest for Sparkle. Add Crest under System Settings → Privacy & Security → Developer Tools, then try again."
        }
        let detail = lastMeaningfulLine(of: recent.joined(separator: "\n")) ?? "exit status \(code)"
        return "The update could not be built: \(detail) See \(BrowserSourceUpdateProcess.logURL.path)."
    }

    private static func lastMeaningfulLine(of output: String) -> String? {
        output.split(separator: "\n").map(String.init).last { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.contains("warning:") && !trimmed.hasPrefix("|")
                && !trimmed.contains("exit code 0 but produced no further output")
                && !trimmed.contains("replacing existing signature")
                && !trimmed.hasPrefix("SwiftCompile")
        }
    }

    // MARK: - Mutators

    func setAutomaticallyChecksForUpdates(_ isEnabled: Bool) {
        preferences.set(isEnabled, forKey: Self.automaticChecksKey)
    }

    func setAutomaticallyBuildsUpdates(_ isEnabled: Bool) {
        preferences.set(isEnabled, forKey: Self.automaticBuildsKey)
    }
}
