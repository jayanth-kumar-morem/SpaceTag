import Foundation

/// Persists custom desktop names, keyed by space UUID.
///
/// Stored outside WindowServer on purpose -- see the note in SkyLight.swift
/// about why writing the real space name is unsafe.
final class NameStore {
    static let shared = NameStore()

    private let fileURL: URL
    private var names: [String: String] = [:]

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpaceTag", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("names.json")
        load()
    }

    var storagePath: String { fileURL.path }

    func name(for space: Space) -> String? {
        guard let value = names[space.key], !value.isEmpty else { return nil }
        return value
    }

    /// Set a custom name, or pass nil/empty to clear it.
    func setName(_ name: String?, for space: Space) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            names.removeValue(forKey: space.key)
        } else {
            names[space.key] = trimmed
        }
        save()
    }

    func clearAll() {
        names.removeAll()
        save()
    }

    /// Drop names whose space no longer exists, so the file does not grow
    /// forever as desktops are created and destroyed.
    func prune(keeping spaces: [Space]) {
        let live = Set(spaces.map(\.key))
        let before = names.count
        names = names.filter { live.contains($0.key) }
        if names.count != before { save() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        names = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(names) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
