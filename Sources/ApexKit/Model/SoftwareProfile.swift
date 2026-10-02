import Foundation

/// A named snapshot of the entire configurable state, stored on the host
/// (PRD-06).
///
/// This is the *software* tier of the two-tier profile system. The keyboard's
/// five onboard flash slots are the other tier; writing a chosen profile into a
/// chosen slot is PRD-05 and is not attempted here — applying a software profile
/// means pushing the same live commands the UI uses. The app's automatic save then
/// writes the result into slot 0, as it does after any other change.
public struct SoftwareProfile: Codable, Identifiable, Equatable, Sendable {
    /// Bumped when a field's *meaning* changes, not when one is added — new
    /// optional fields are handled by the tolerant decoders on each config.
    public static let currentSchemaVersion = 1

    public var id: UUID = UUID()
    public var name: String = "Untitled"
    public var schemaVersion: Int = SoftwareProfile.currentSchemaVersion
    public var createdAt: Date = Date()
    public var modifiedAt: Date = Date()

    public var lighting: LightingConfig = LightingConfig()
    public var actuation: ActuationConfig = ActuationConfig()
    public var rapidTap: RapidTapConfig = RapidTapConfig()
    public var bindings: BindingsConfig = BindingsConfig()
    public var oled: OLEDConfig = OLEDConfig()

    public init() {}

    /// Every field is optional on decode, so a profile written by an older or
    /// newer build still loads instead of failing the whole library.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
        lighting = try c.decodeIfPresent(LightingConfig.self, forKey: .lighting) ?? LightingConfig()
        actuation = try c.decodeIfPresent(ActuationConfig.self, forKey: .actuation) ?? ActuationConfig()
        rapidTap = try c.decodeIfPresent(RapidTapConfig.self, forKey: .rapidTap) ?? RapidTapConfig()
        bindings = try c.decodeIfPresent(BindingsConfig.self, forKey: .bindings) ?? BindingsConfig()
        oled = try c.decodeIfPresent(OLEDConfig.self, forKey: .oled) ?? OLEDConfig()
    }

    /// True when two profiles hold the same settings, ignoring identity and
    /// timestamps — used to show the "modified since applied" dot.
    public func hasSameSettings(as other: SoftwareProfile) -> Bool {
        lighting == other.lighting && actuation == other.actuation
            && rapidTap == other.rapidTap && bindings == other.bindings && oled == other.oled
    }

    /// One-line summary for the profile list.
    public var summary: String {
        var parts: [String] = [lighting.kind.rawValue]
        parts.append(String(format: "%.1f mm", Actuation.millimetres(forLevel: actuation.globalLevel)))
        if actuation.rapidTrigger { parts.append("RT") }
        if rapidTap.enabled { parts.append("SOCD") }
        if !bindings.isEmpty { parts.append("\(bindings.changedCount) binds") }
        if oled.mode != .off { parts.append("OLED \(oled.mode.rawValue)") }
        return parts.joined(separator: " · ")
    }
}
