import Foundation
import Observation

/// What a plugin hears about the Spaces of the browsing session: Spaces
/// appearing and going, the window's shown Space moving, and any change to
/// the session's tabs. Every closure is optional; a plugin fills the ones it
/// acts on. The host calls them on the main actor after the read model has
/// taken the change, so what a closure reads from the stores is current.
struct CrestPluginSpaceObserver: Identifiable {
    // MARK: - Static Variables

    static let hook = CrestPluginHookPoint<CrestPluginSpaceObserver>(id: "spaces.lifecycle", version: 1)

    // MARK: - Variables

    let id: String
    /// Spaces that appeared since the last report: created, imported or
    /// delivered by sync.
    var spacesAdded: (@MainActor ([SpaceModel]) -> Void)? = nil
    /// Spaces that went since the last report, by identity; the host has
    /// already dropped every plugin's storage for them.
    var spacesRemoved: (@MainActor ([UUID]) -> Void)? = nil
    /// The Space the main window shows changed; nil while it shows none, as
    /// during a deletion.
    var shownSpaceChanged: (@MainActor (SpaceModel?) -> Void)? = nil
    /// The session changed in any way: a tab opened, moved, renamed or
    /// closed, a Space renamed. Reported once per core batch.
    var sessionChanged: (@MainActor () -> Void)? = nil
}

/// Watches the browsing session on the host's behalf and reports to every
/// active observer: which Spaces came and went, which the window shows, and
/// each revision of the session. Re-arms its observation after every change,
/// as Crest's own services do.
@MainActor
final class CrestPluginSpaceWatcher {
    // MARK: - Variables

    private let browser: BrowserStore
    private let contributions: CrestPluginContributions
    /// Drops every plugin's storage for a deleted Space.
    private let spaceRemoved: @MainActor (UUID) -> Void
    private var knownSpaceIDs: [UUID]
    private var shownSpaceID: UUID?
    private var sessionRevision: BrowserSessionRevision
    private var stopped = false

    // MARK: - Initializers

    init(
        browser: BrowserStore, contributions: CrestPluginContributions,
        spaceRemoved: @escaping @MainActor (UUID) -> Void
    ) {
        self.browser = browser
        self.contributions = contributions
        self.spaceRemoved = spaceRemoved
        knownSpaceIDs = browser.spaceModels.map(\.id)
        shownSpaceID = browser.shownSpace?.id
        sessionRevision = browser.sessionRevision
    }

    // MARK: - Actions - Watching

    func start() {
        follow()
    }

    func stop() {
        stopped = true
    }

    private func follow() {
        guard !stopped else { return }
        // Only the three readings are tracked; what an observer reads while it
        // acts on them is its own, so a report never re-arms itself.
        let (spaceIDs, shownSpaceID, revision) = withObservationTracking {
            (browser.spaceModels.map(\.id), browser.shownSpace?.id, browser.sessionRevision)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        report(spaceIDs: spaceIDs, shownSpaceID: shownSpaceID, revision: revision)
    }

    private func report(spaceIDs: [UUID], shownSpaceID: UUID?, revision: BrowserSessionRevision) {
        let observers = contributions.contributions(at: CrestPluginSpaceObserver.hook)
        let known = Set(knownSpaceIDs)
        let current = Set(spaceIDs)
        let removed = knownSpaceIDs.filter { !current.contains($0) }
        let added = spaceIDs.filter { !known.contains($0) }.compactMap(browser.spaceModel)
        knownSpaceIDs = spaceIDs
        if !removed.isEmpty {
            removed.forEach(spaceRemoved)
            for observer in observers { observer.spacesRemoved?(removed) }
        }
        if !added.isEmpty {
            for observer in observers { observer.spacesAdded?(added) }
        }
        if shownSpaceID != self.shownSpaceID {
            self.shownSpaceID = shownSpaceID
            let shown = shownSpaceID.flatMap(browser.spaceModel)
            for observer in observers { observer.shownSpaceChanged?(shown) }
        }
        if revision != sessionRevision {
            sessionRevision = revision
            for observer in observers { observer.sessionChanged?() }
        }
    }
}
