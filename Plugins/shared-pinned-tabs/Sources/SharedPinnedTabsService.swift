import Foundation
import Observation

/// Keeps the pinned tabs shared between Spaces: which pinned tab is the home
/// of which copies, makes and removes the copies, runs every copy's pages in
/// the home Space's profile, and keeps the copies in step with their home
/// tab. What it knows lives in the plugin's storage; the core learns the
/// profile assignments again at every launch.
@MainActor
@Observable
final class SharedPinnedTabsService {
    // MARK: - Types

    /// One shared pinned tab: its home, and a copy in each Space it is shared
    /// into.
    struct Share: Codable, Identifiable, Equatable {
        let homeTabID: UUID
        let homeSpaceID: UUID
        var mirrors: [Mirror]

        var id: UUID { homeTabID }

        func mirror(in spaceID: UUID) -> Mirror? {
            mirrors.first { $0.spaceID == spaceID }
        }
    }

    /// A copy of a shared tab: a real pinned tab of another Space, whose
    /// pages run in the home Space's profile.
    struct Mirror: Codable, Equatable {
        let spaceID: UUID
        let tabID: UUID
    }

    // MARK: - Static Variables

    static let sharesKey = "shares"
    static let followsHomeKey = "mirrorsFollowHome"

    // MARK: - Variables

    let browser: BrowserStore
    let storage: CrestPluginStorage
    private(set) var shares: [Share]
    /// The copies whose profile the core has taken this run. One the core
    /// refused, as before its workspace is attached, is sent again at the next
    /// session change.
    @ObservationIgnored private var assignedMirrorIDs: Set<UUID> = []

    /// Whether the copies take the home tab's saved address, name and emoji
    /// icon whenever those change. Off, each copy keeps what it was given.
    var mirrorsFollowHome: Bool {
        get { storage.value(Bool.self, forKey: Self.followsHomeKey) ?? true }
        set { storage.set(newValue, forKey: Self.followsHomeKey) }
    }

    // MARK: - Initializers

    init(browser: BrowserStore, storage: CrestPluginStorage) {
        self.browser = browser
        self.storage = storage
        shares = storage.value([Share].self, forKey: Self.sharesKey) ?? []
    }

    // MARK: - Actions - Launch

    /// Tells the core which profile every copy runs in, and drops what the
    /// session no longer holds.
    func start() {
        reconcile()
    }

    /// Takes every assignment back; the copies stay as ordinary pinned tabs of
    /// their Spaces until the plugin runs again.
    func stop() {
        for share in shares {
            for mirror in share.mirrors {
                browser.assignTabProfile(nil, to: mirror.tabID)
            }
        }
        assignedMirrorIDs = []
    }

    /// Gives the core the copy's profile, once it takes it.
    private func assign(_ mirror: Mirror, profileID: UUID) {
        guard !assignedMirrorIDs.contains(mirror.tabID) else { return }
        if browser.assignTabProfile(profileID, to: mirror.tabID) { assignedMirrorIDs.insert(mirror.tabID) }
    }

    /// Takes the copy's profile back.
    private func unassign(_ mirror: Mirror) {
        browser.assignTabProfile(nil, to: mirror.tabID)
        assignedMirrorIDs.remove(mirror.tabID)
    }

    // MARK: - Actions - Reading

    /// The share whose home is `tabID`, if the tab is shared.
    func share(ofHome tabID: UUID) -> Share? {
        shares.first { $0.homeTabID == tabID }
    }

    /// The share a copy belongs to, if `tabID` is a copy.
    func share(ofMirror tabID: UUID) -> Share? {
        shares.first { share in share.mirrors.contains { $0.tabID == tabID } }
    }

    func isMirror(_ tabID: UUID) -> Bool {
        share(ofMirror: tabID) != nil
    }

    func isShared(_ homeTabID: UUID, in spaceID: UUID) -> Bool {
        share(ofHome: homeTabID)?.mirror(in: spaceID) != nil
    }

    /// The Spaces a pinned tab of `homeSpaceID` may be shared into: every
    /// other Space.
    func candidateSpaces(forHomeIn homeSpaceID: UUID) -> [SpaceModel] {
        browser.spaceModels.filter { $0.id != homeSpaceID }
    }

    // MARK: - Actions - Sharing

    /// Shares the pinned tab `home` into `spaceID`, or stops sharing it there.
    func setShared(_ isShared: Bool, home: BrowserTabRuntimeAssignment, in spaceID: UUID) {
        if isShared {
            share(home: home, in: spaceID)
        } else {
            unshare(homeTabID: home.tabID, in: spaceID)
        }
    }

    /// Removes every copy of the home tab `homeTabID`.
    func stopSharing(homeTabID: UUID) {
        guard let share = share(ofHome: homeTabID) else { return }
        for mirror in share.mirrors {
            removeMirror(mirror)
        }
        shares.removeAll { $0.homeTabID == homeTabID }
        save()
    }

    private func share(home: BrowserTabRuntimeAssignment, in spaceID: UUID) {
        guard !isShared(home.tabID, in: spaceID), spaceID != home.spaceID,
            let homeSpace = browser.spaceModel(home.spaceID), let homeTab = homeSpace.tabs.model(home.tabID),
            homeTab.placement == .pinned, let address = homeTab.savedURL ?? homeTab.url,
            let space = browser.spaceModel(spaceID), !browser.isDeleting(spaceID)
        else { return }
        guard
            let tabID = browser.openSessionTab(
                TabContent(address: address, view: nil, title: homeTab.customTitle), in: space.id, placement: .pinned,
                shouldSelect: false)
        else { return }
        let mirror = Mirror(spaceID: space.id, tabID: tabID)
        assign(mirror, profileID: homeSpace.profileID)
        if homeTab.iconMode == .emoji, let emoji = homeTab.emojiIcon {
            browser.setSessionTabIcon(.emoji, emoji: emoji, tabID: tabID, in: space.id)
        }
        if let index = shares.firstIndex(where: { $0.homeTabID == home.tabID }) {
            shares[index].mirrors.append(mirror)
        } else {
            shares.append(Share(homeTabID: home.tabID, homeSpaceID: home.spaceID, mirrors: [mirror]))
        }
        save()
    }

    private func unshare(homeTabID: UUID, in spaceID: UUID) {
        guard let index = shares.firstIndex(where: { $0.homeTabID == homeTabID }),
            let mirror = shares[index].mirror(in: spaceID)
        else { return }
        removeMirror(mirror)
        shares[index].mirrors.removeAll { $0.spaceID == spaceID }
        if shares[index].mirrors.isEmpty { shares.remove(at: index) }
        save()
    }

    /// Deletes the copy's tab where its Space still holds it, and takes its
    /// profile back.
    private func removeMirror(_ mirror: Mirror) {
        unassign(mirror)
        guard let space = browser.spaceModel(mirror.spaceID), space.tabs.contains(mirror.tabID),
            !browser.isDeleting(mirror.spaceID)
        else { return }
        browser.deleteSessionTab(mirror.tabID, in: mirror.spaceID)
    }

    // MARK: - Actions - Following the session

    /// Drops shares whose home is gone or no longer pinned, copies whose tab is
    /// gone or no longer pinned, and brings the copies in step with their
    /// home where `mirrorsFollowHome` asks for it.
    func reconcile() {
        var changed = false
        for share in shares {
            guard let homeSpace = browser.spaceModel(share.homeSpaceID), !browser.isDeleting(homeSpace.id),
                let homeTab = homeSpace.tabs.model(share.homeTabID), homeTab.placement == .pinned
            else {
                for mirror in share.mirrors { removeMirror(mirror) }
                shares.removeAll { $0.homeTabID == share.homeTabID }
                changed = true
                continue
            }
            var kept: [Mirror] = []
            for mirror in share.mirrors {
                guard let space = browser.spaceModel(mirror.spaceID), let tab = space.tabs.model(mirror.tabID),
                    tab.placement == .pinned
                else {
                    unassign(mirror)
                    changed = true
                    continue
                }
                kept.append(mirror)
                assign(mirror, profileID: homeSpace.profileID)
                if mirrorsFollowHome { follow(homeTab, with: tab, in: space) }
            }
            if kept.isEmpty {
                shares.removeAll { $0.homeTabID == share.homeTabID }
                changed = true
            } else if kept != share.mirrors, let index = shares.firstIndex(where: { $0.homeTabID == share.homeTabID }) {
                shares[index].mirrors = kept
            }
        }
        if changed { save() }
    }

    /// Spaces went: a home Space takes its copies with it, a member Space its
    /// copy. The session has already dropped their tabs.
    func spacesRemoved(_ spaceIDs: [UUID]) {
        let gone = Set(spaceIDs)
        var changed = false
        for share in shares {
            if gone.contains(share.homeSpaceID) {
                for mirror in share.mirrors { removeMirror(mirror) }
                shares.removeAll { $0.homeTabID == share.homeTabID }
                changed = true
            } else if share.mirrors.contains(where: { gone.contains($0.spaceID) }),
                let index = shares.firstIndex(where: { $0.homeTabID == share.homeTabID })
            {
                shares[index].mirrors.removeAll { gone.contains($0.spaceID) }
                if shares[index].mirrors.isEmpty { shares.remove(at: index) }
                changed = true
            }
        }
        if changed { save() }
    }

    /// Gives the copy `mirror` what its home has: saved address, name and
    /// emoji icon, each only where it differs, so a copy that is in step
    /// changes nothing.
    private func follow(_ home: TabStateModel, with mirror: TabStateModel, in space: SpaceModel) {
        if let address = home.savedURL, mirror.savedURL != address {
            if browser.adoptTabSavedAddress(address, for: mirror.id, in: space.id) {
                browser.returnSessionTabToSavedAddress(tabID: mirror.id, in: space.id)
            }
        }
        if mirror.customTitle != home.customTitle {
            browser.renameSessionTab(home.customTitle, tabID: mirror.id, in: space.id)
        }
        if home.iconMode == .emoji {
            if let emoji = home.emojiIcon, mirror.iconMode != .emoji || mirror.emojiIcon != emoji {
                browser.setSessionTabIcon(.emoji, emoji: emoji, tabID: mirror.id, in: space.id)
            }
        } else if mirror.iconMode == .emoji {
            browser.setSessionTabIcon(.automatic, tabID: mirror.id, in: space.id)
        }
    }

    // MARK: - Mutators

    private func save() {
        storage.set(shares, forKey: Self.sharesKey)
    }
}
