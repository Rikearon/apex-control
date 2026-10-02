import Foundation
import SwiftUI
import ApexKit

/// The on-disk library: every profile plus the onboard slot assignments.
private struct ProfileLibrary: Codable {
    var schemaVersion: Int = SoftwareProfile.currentSchemaVersion
    var profiles: [SoftwareProfile] = []
    /// Five entries, slot 0…4, each a profile id or nil.
    var onboardSlots: [UUID?] = Array(repeating: nil, count: 5)
    var appliedProfileID: UUID?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        profiles = try c.decodeIfPresent([SoftwareProfile].self, forKey: .profiles) ?? []
        var slots = try c.decodeIfPresent([UUID?].self, forKey: .onboardSlots) ?? []
        while slots.count < 5 { slots.append(nil) }
        onboardSlots = Array(slots.prefix(5))
        appliedProfileID = try c.decodeIfPresent(UUID.self, forKey: .appliedProfileID)
    }
}

/// Owns the profile library: CRUD, atomic persistence, import/export, and the
/// onboard slot map.
@MainActor
final class ProfileStore: ObservableObject {

    @Published private(set) var profiles: [SoftwareProfile] = []
    @Published private(set) var onboardSlots: [UUID?] = Array(repeating: nil, count: 5)
    /// The profile whose settings were last pushed to the keyboard.
    @Published private(set) var appliedProfileID: UUID?
    /// The last onboard slot this app commanded. The keyboard offers no query
    /// for the active slot, so this is intent, not truth (PRD-06 §9).
    @Published private(set) var lastCommandedSlot: UInt8?
    @Published var selectedProfileID: UUID?
    @Published var lastError: String?

    private let fileURL: URL
    private var loaded = false

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ApexControl", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("profiles.json")
    }

    // MARK: - Persistence

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Load the library. A corrupt file is preserved (renamed) rather than
    /// overwritten, so a bad parse never silently destroys someone's profiles.
    func load() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let library = try Self.makeDecoder().decode(ProfileLibrary.self, from: data)
            profiles = library.profiles
            onboardSlots = library.onboardSlots
            appliedProfileID = library.appliedProfileID
            selectedProfileID = library.appliedProfileID ?? library.profiles.first?.id
        } catch {
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("profiles-corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            lastError = "Could not read your profiles (\(error.localizedDescription)). "
                + "The file was kept at \(backup.lastPathComponent) and a fresh library was started."
        }
    }

    /// Write the library atomically (temp file + replace) so a crash mid-write
    /// cannot truncate it.
    private func save() {
        var library = ProfileLibrary()
        library.profiles = profiles
        library.onboardSlots = onboardSlots
        library.appliedProfileID = appliedProfileID
        do {
            let data = try Self.makeEncoder().encode(library)
            let tmp = fileURL.deletingLastPathComponent()
                .appendingPathComponent(".profiles.json.\(UUID().uuidString).tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } catch {
            lastError = "Could not save profiles: \(error.localizedDescription)"
        }
    }

    // MARK: - Lookup

    func profile(id: UUID?) -> SoftwareProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    var selectedProfile: SoftwareProfile? { profile(id: selectedProfileID) }

    func name(forSlot slot: Int) -> String? {
        guard onboardSlots.indices.contains(slot) else { return nil }
        return profile(id: onboardSlots[slot])?.name
    }

    // MARK: - CRUD

    @discardableResult
    func add(_ profile: SoftwareProfile, select: Bool = true) -> SoftwareProfile {
        var p = profile
        p.name = uniqueName(p.name)
        profiles.append(p)
        if select { selectedProfileID = p.id }
        save()
        return p
    }

    func update(_ profile: SoftwareProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var p = profile
        p.modifiedAt = Date()
        profiles[idx] = p
        save()
    }

    func rename(id: UUID, to newName: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profiles[idx].name = uniqueName(trimmed, excluding: id)
        profiles[idx].modifiedAt = Date()
        save()
    }

    @discardableResult
    func duplicate(id: UUID) -> SoftwareProfile? {
        guard var copy = profile(id: id) else { return nil }
        copy.id = UUID()
        copy.name = uniqueName(copy.name + " Copy")
        copy.createdAt = Date()
        copy.modifiedAt = Date()
        profiles.append(copy)
        selectedProfileID = copy.id
        save()
        return copy
    }

    func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
        // Never leave a dangling slot assignment or a phantom "applied" badge.
        for i in onboardSlots.indices where onboardSlots[i] == id { onboardSlots[i] = nil }
        if appliedProfileID == id { appliedProfileID = nil }
        if selectedProfileID == id { selectedProfileID = profiles.first?.id }
        save()
    }

    func markApplied(_ id: UUID?) {
        appliedProfileID = id
        save()
    }

    func assign(profileID: UUID?, toSlot slot: Int) {
        guard onboardSlots.indices.contains(slot) else { return }
        onboardSlots[slot] = profileID
        save()
    }

    func noteCommandedSlot(_ slot: UInt8) {
        lastCommandedSlot = slot
    }

    /// A default name for "save what the keyboard is doing now".
    func nextProfileName() -> String { uniqueName("Profile \(profiles.count + 1)") }

    private func uniqueName(_ base: String, excluding id: UUID? = nil) -> String {
        let existing = Set(profiles.filter { $0.id != id }.map(\.name))
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Import / export

    func export(id: UUID, to url: URL) {
        guard let p = profile(id: id) else { return }
        do {
            try Self.makeEncoder().encode(p).write(to: url, options: .atomic)
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Import a profile file. The library is left untouched on failure.
    @discardableResult
    func importProfile(from url: URL) -> SoftwareProfile? {
        do {
            let data = try Data(contentsOf: url)
            var imported = try Self.makeDecoder().decode(SoftwareProfile.self, from: data)
            imported.id = UUID()                 // always a fresh identity
            imported.createdAt = Date()
            imported.modifiedAt = Date()
            if imported.name.isEmpty { imported.name = url.deletingPathExtension().lastPathComponent }
            lastError = nil
            return add(imported)
        } catch {
            lastError = "“\(url.lastPathComponent)” is not a valid Apex Control profile "
                + "(\(error.localizedDescription))."
            return nil
        }
    }
}
