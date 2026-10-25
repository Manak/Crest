import Foundation
import Observation
import SwiftUI

/// A seam in Crest where plugins contribute values of one kind. The id names
/// the hook in the catalog; the version rises when the contribution's shape
/// changes, so a plugin written for an older shape is left out rather than
/// miscompiled.
struct CrestPluginHookPoint<Contribution>: Sendable {
    let id: String
    let version: Int
}

/// What the active plugins contributed, kept by the host and read at the
/// seams. A view that reads it follows a plugin being turned on or off.
@MainActor
@Observable
final class CrestPluginContributions {
    // MARK: - Types

    private struct Entry {
        let pluginID: String
        let contribution: Any
    }

    // MARK: - Variables

    private var entries: [String: [Entry]] = [:]
    /// The plugins whose contributions count, and whose patch-only behavior
    /// runs. A plugin turned off keeps its entries but none of them show.
    private(set) var activePluginIDs: Set<String> = []

    // MARK: - Actions - Registration

    func register<Contribution>(
        _ contribution: Contribution, at point: CrestPluginHookPoint<Contribution>, from pluginID: String
    ) {
        entries[point.id, default: []].append(Entry(pluginID: pluginID, contribution: contribution))
    }

    func removeAll(from pluginID: String) {
        for key in entries.keys {
            entries[key]?.removeAll { $0.pluginID == pluginID }
        }
    }

    func setActive(_ isActive: Bool, _ pluginID: String) {
        if isActive {
            activePluginIDs.insert(pluginID)
        } else {
            activePluginIDs.remove(pluginID)
        }
    }

    // MARK: - Actions - Reading

    /// The active plugins' contributions at `point`, in registration order.
    func contributions<Contribution>(at point: CrestPluginHookPoint<Contribution>) -> [Contribution] {
        (entries[point.id] ?? []).compactMap { entry in
            guard activePluginIDs.contains(entry.pluginID) else { return nil }
            return entry.contribution as? Contribution
        }
    }

    func isActive(_ pluginID: String) -> Bool {
        activePluginIDs.contains(pluginID)
    }
}

/// The hooks a view or model reads: the host's contributions, or none where no
/// host runs, as on iPhone and iPad and in tests. Views take it from the
/// environment; AppKit code with no environment, such as an event monitor,
/// reads `installed`.
struct CrestPluginHooks: Sendable {
    // MARK: - Static Variables

    static let none = CrestPluginHooks(contributions: nil)

    /// The hooks of the host this process runs, from the moment it starts.
    @MainActor static var installed = CrestPluginHooks.none

    // MARK: - Variables

    let contributions: CrestPluginContributions?

    // MARK: - Actions - Reading

    @MainActor
    func contributions<Contribution>(at point: CrestPluginHookPoint<Contribution>) -> [Contribution] {
        contributions?.contributions(at: point) ?? []
    }

    /// The one contribution at a seam that takes a single winner: the first
    /// active plugin's, in the catalog's order.
    @MainActor
    func first<Contribution>(at point: CrestPluginHookPoint<Contribution>) -> Contribution? {
        contributions(at: point).first
    }

    /// Whether a plugin is on, for behavior a plugin's own patch carries.
    @MainActor
    func isEnabled(_ pluginID: String) -> Bool {
        contributions?.isActive(pluginID) ?? false
    }
}

extension EnvironmentValues {
    @Entry var crestPluginHooks = CrestPluginHooks.none
}
