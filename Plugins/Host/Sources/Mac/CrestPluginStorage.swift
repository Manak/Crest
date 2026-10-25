import CryptoKit
import Foundation
import Observation
import SwiftUI

/// Where a plugin keeps what it knows between launches: one JSON document per
/// plugin, held apart from every other plugin's and from Crest's own data, with
/// values keyed by name and, where a value belongs to one Space, by that Space
/// too. Values are `Codable`; the document on disk is plain JSON a person can
/// read. Reading a value observes it, so a settings view follows a change.
///
/// An installed launch keeps the documents under
/// `Application Support/Crest/Plugins/<plugin id>/storage.json`; a named
/// isolated launch keeps them under `Plugins/Isolated/<namespace>/`; any other
/// isolated launch, and a test, keeps them in memory only.
@MainActor
@Observable
final class CrestPluginStorage {
    // MARK: - Types

    /// The storage of one Space within a plugin's: the same keys, scoped to
    /// the Space, and gone with it.
    @MainActor
    struct Space {
        let storage: CrestPluginStorage
        let spaceID: UUID

        func value<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
            storage.value(type, forKey: key, in: spaceID)
        }

        func set<Value: Encodable>(_ value: Value?, forKey key: String) {
            storage.set(value, forKey: key, in: spaceID)
        }

        func removeValue(forKey key: String) {
            storage.set(Optional<Int>.none, forKey: key, in: spaceID)
        }

        var keys: [String] {
            storage.keys(in: spaceID)
        }

        /// A binding over one value of this Space, for a control in a settings
        /// section; `defaultValue` stands in until the control sets one.
        func binding<Value: Codable>(_ key: String, default defaultValue: Value) -> Binding<Value> {
            storage.binding(key, in: spaceID, default: defaultValue)
        }
    }

    /// The document as written: the plugin-wide values, and each Space's.
    private struct Document {
        static let valuesKey = "values"
        static let spacesKey = "spaces"

        var values: [String: Any] = [:]
        var spaces: [String: [String: Any]] = [:]

        init() {}

        init(json: Any) {
            guard let object = json as? [String: Any] else { return }
            values = object[Self.valuesKey] as? [String: Any] ?? [:]
            spaces = (object[Self.spacesKey] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
        }

        var json: [String: Any] {
            [Self.valuesKey: values, Self.spacesKey: spaces]
        }
    }

    // MARK: - Static Variables

    static let directoryName = "Plugins"
    static let fileName = "storage.json"

    // MARK: - Variables

    let pluginID: String
    /// Where the document lives, or nil for a launch that keeps it in memory.
    let fileURL: URL?
    /// Moves whenever a value changes; a reader of any value observes it.
    private(set) var revision = 0

    @ObservationIgnored private var document = Document()
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    /// Whether what is stored outlives this launch.
    var isPersistent: Bool { fileURL != nil }

    /// Every plugin-wide key, sorted.
    var keys: [String] {
        _ = revision
        return document.values.keys.sorted()
    }

    /// Every Space the storage holds values for.
    var spaceIDs: [UUID] {
        _ = revision
        return document.spaces.keys.compactMap(UUID.init(uuidString:))
    }

    /// Whether the storage holds nothing.
    var isEmpty: Bool {
        _ = revision
        return document.values.isEmpty && document.spaces.values.allSatisfy(\.isEmpty)
    }

    // MARK: - Initializers

    init(pluginID: String, fileURL: URL?) {
        self.pluginID = pluginID
        self.fileURL = fileURL
        encoder.outputFormatting = [.sortedKeys]
        load()
    }

    /// The storage of `pluginID` for `environment`: on disk for an installed
    /// or named isolated launch, in memory for every other.
    static func forLaunch(_ environment: BrowserLaunchEnvironment, pluginID: String) -> CrestPluginStorage {
        CrestPluginStorage(
            pluginID: pluginID,
            fileURL: rootDirectory(for: environment)?.appendingPathComponent(pluginID, isDirectory: true))
    }

    /// The folder every plugin's documents sit under for `environment`, or
    /// nil for a launch that keeps nothing.
    static func rootDirectory(for environment: BrowserLaunchEnvironment) -> URL? {
        guard
            let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first
        else { return nil }
        let base =
            applicationSupport
            .appendingPathComponent(ProductIdentity.storageDirectoryName, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        guard environment.requiresIsolation else { return base }
        guard !environment.isXCTestRuntime, !environment.isSwiftUIPreviewRuntime,
            let identity = environment.persistentIsolationID
        else { return nil }
        let namespace = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return
            base
            .appendingPathComponent("Isolated", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
    }

    // MARK: - Actions - Reading

    /// The plugin-wide value under `key`, or nil where none is stored or the
    /// stored one no longer decodes as `type`.
    func value<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        _ = revision
        return decode(type, document.values[key])
    }

    /// The value under `key` for `spaceID`.
    func value<Value: Decodable>(_ type: Value.Type, forKey key: String, in spaceID: UUID) -> Value? {
        _ = revision
        return decode(type, document.spaces[spaceID.uuidString]?[key])
    }

    /// The storage of one Space: the same keys, scoped to it.
    func space(_ spaceID: UUID) -> Space {
        Space(storage: self, spaceID: spaceID)
    }

    func keys(in spaceID: UUID) -> [String] {
        _ = revision
        return document.spaces[spaceID.uuidString]?.keys.sorted() ?? []
    }

    /// A binding over one plugin-wide value, for a control in a settings
    /// section; `defaultValue` stands in until the control sets one.
    func binding<Value: Codable>(_ key: String, default defaultValue: Value) -> Binding<Value> {
        Binding(
            get: { self.value(Value.self, forKey: key) ?? defaultValue },
            set: { self.set($0, forKey: key) })
    }

    func binding<Value: Codable>(_ key: String, in spaceID: UUID, default defaultValue: Value) -> Binding<Value> {
        Binding(
            get: { self.value(Value.self, forKey: key, in: spaceID) ?? defaultValue },
            set: { self.set($0, forKey: key, in: spaceID) })
    }

    // MARK: - Mutators

    /// Stores `value` under `key`, or removes the key for nil.
    func set<Value: Encodable>(_ value: Value?, forKey key: String) {
        guard let encoded = encode(value) else {
            guard document.values.removeValue(forKey: key) != nil else { return }
            return commit()
        }
        document.values[key] = encoded
        commit()
    }

    /// Stores `value` under `key` for `spaceID`, or removes the key for nil.
    func set<Value: Encodable>(_ value: Value?, forKey key: String, in spaceID: UUID) {
        let spaceKey = spaceID.uuidString
        guard let encoded = encode(value) else {
            guard document.spaces[spaceKey]?.removeValue(forKey: key) != nil else { return }
            if document.spaces[spaceKey]?.isEmpty == true { document.spaces.removeValue(forKey: spaceKey) }
            return commit()
        }
        document.spaces[spaceKey, default: [:]][key] = encoded
        commit()
    }

    func removeValue(forKey key: String) {
        set(Optional<Int>.none, forKey: key)
    }

    /// Drops everything stored for `spaceID`. The host calls it when the Space
    /// is deleted; a plugin may call it when a Space stops concerning it.
    func forgetSpace(_ spaceID: UUID) {
        guard document.spaces.removeValue(forKey: spaceID.uuidString) != nil else { return }
        commit()
    }

    /// Drops everything the plugin stored.
    func removeAll() {
        document = Document()
        commit()
    }

    // MARK: - Actions - Coding

    private func encode<Value: Encodable>(_ value: Value?) -> Any? {
        guard let value else { return nil }
        guard let data = try? encoder.encode(value),
            let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return json
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ json: Any?) -> Value? {
        guard let json, let data = try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])
        else { return nil }
        return try? decoder.decode(type, from: data)
    }

    // MARK: - Actions - Disk

    private func load() {
        guard let url = fileURL?.appendingPathComponent(Self.fileName), let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data)
        else { return }
        document = Document(json: json)
    }

    private func commit() {
        revision &+= 1
        guard let directory = fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: document.json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
        } catch {
            // A document that cannot be written stays in memory for this
            // launch; the next successful write carries everything.
        }
    }
}
