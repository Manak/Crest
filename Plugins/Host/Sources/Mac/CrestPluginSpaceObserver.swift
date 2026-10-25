import Foundation
import Observation

/// What a plugin hears about the Spaces of the browsing session: Spaces
/// appearing and going, the window's shown Space moving, any change to the
/// session's tabs, and the tabs' pages opening and going. Every closure is
/// optional; a plugin fills the ones it acts on. The host calls them on the
/// main actor after the read model has taken the change, so what a closure
/// reads from the stores is current.
struct CrestPluginSpaceObserver: Identifiable {
    // MARK: - Static Variables

    static let hook = CrestPluginHookPoint<CrestPluginSpaceObserver>(id: "spaces.lifecycle", version: 2)

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
    /// The tabs with a page changed: a tab's page opened in some window of
    /// either browsing mode, or went, unloaded, put away or closed. Reported
    /// once per core batch; a page's own navigation is not reported.
    var pagesChanged: (@MainActor () -> Void)? = nil
}

/// Watches the browsing session on the host's behalf and reports to every
/// active observer: which Spaces came and went, which the window shows, each
/// revision of the session, and which tabs have a page. Re-arms its
/// observation after every change, as Crest's own services do.
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
    private var pagedTabIDs: Set<UUID>
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
        pagedTabIDs = Self.pagedTabIDs(in: browser)
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
        // Only the four readings are tracked; what an observer reads while it
        // acts on them is its own, so a report never re-arms itself.
        let (spaceIDs, shownSpaceID, revision, pagedTabIDs) = withObservationTracking {
            (
                browser.spaceModels.map(\.id), browser.shownSpace?.id, browser.sessionRevision,
                Self.pagedTabIDs(in: browser)
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        report(spaceIDs: spaceIDs, shownSpaceID: shownSpaceID, revision: revision, pagedTabIDs: pagedTabIDs)
    }

    /// Every tab with a page, in any window of either browsing mode.
    private static func pagedTabIDs(in browser: BrowserStore) -> Set<UUID> {
        Set(browser.core.state.pages.values.compactMap(\.tabID))
    }

    private func report(
        spaceIDs: [UUID], shownSpaceID: UUID?, revision: BrowserSessionRevision, pagedTabIDs: Set<UUID>
    ) {
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
        if pagedTabIDs != self.pagedTabIDs {
            self.pagedTabIDs = pagedTabIDs
            for observer in observers { observer.pagesChanged?() }
        }
    }
}
