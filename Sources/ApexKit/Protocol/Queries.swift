import Foundation

/// Read-back queries and lifecycle commands.
///
/// Query APIs write a short Output report and read the reply as an Input report.
/// Commands: firmware version 0x90, layout 0xF2, region read 0xF5 and region
/// write 0x75 (from the vendor's description of the device), and the
/// community-confirmed init 0x4B.
public enum Queries {

    // Request builders (Output reports; report ID 0 sent separately).
    public static func firmwareVersionRequest() -> [UInt8] { [0x90, 0x00] }
    public static func ledFirmwareVersionRequest() -> [UInt8] { [0x90, 0x01] }
    public static func readRegionRequest() -> [UInt8] { [0xF5] }
    public static func readLayoutRequest() -> [UInt8] { [0xF2] }

    /// Writes region to flash — only send on a genuine user change.
    public static func writeRegion(_ regionID: UInt8) -> [UInt8] { [0x75, regionID] }

    /// Community-derived "enable direct/driver mode" init: other RGB tools are
    /// reported to send it before driving the LEDs. Harmless to repeat; whether
    /// this keyboard strictly needs it is not established here.
    public static func initDirectMode() -> [UInt8] { [0x4B] }

    /// Set which onboard profile (0…4) is active.
    public static func loadProfile(_ id: UInt8) -> [UInt8] { [0xB2, id] }

    /// `set_profile_volatile`. Declared in the vendor descriptor but **not**
    /// byte-verified on hardware, and which argument means "revert on power
    /// cycle" is unconfirmed — see PRD-06 §12.
    public static func setProfileVolatile(_ volatile: Bool) -> [UInt8] { [0x34, volatile ? 1 : 0] }

    /// Set the meta/Fn toggle key by HID code. (`Mappings.metaToggle` is the
    /// canonical builder; kept here for symmetry with the other lifecycle
    /// commands.)
    public static func metaToggleHID(_ hid: UInt8) -> [UInt8] { [0x35, hid] }

    // Reply parsers.

    /// Parse a firmware-version reply. The reply echoes `0x90 0x00` then ASCII.
    public static func parseFirmware(_ reply: [UInt8]) -> String? {
        guard !reply.isEmpty else { return nil }
        // Strip a leading 0x90 [0x00] echo if present.
        var bytes = reply
        if bytes.first == 0x90 { bytes.removeFirst(); if bytes.first == 0x00 { bytes.removeFirst() } }
        let ascii = bytes.prefix { $0 >= 0x20 && $0 < 0x7F }
        let s = String(bytes: ascii, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
        return (s?.isEmpty == false) ? s : nil
    }

    public struct RegionInfo: Sendable {
        public let regionID: UInt8
        public let name: String
    }

    public static let regionNames: [UInt8: String] = [
        1: "US", 3: "UK", 4: "Germany", 6: "France", 10: "Nordic", 13: "Japan", 20: "Turkish",
    ]

    /// Parse a `read_region` reply: `[0xF5, err, region_id]`.
    public static func parseRegion(_ reply: [UInt8]) -> RegionInfo? {
        guard let idx = reply.firstIndex(of: 0xF5), reply.count >= idx + 3 else {
            // Some stacks drop the echo; fall back to 3rd byte.
            if reply.count >= 3 { return RegionInfo(regionID: reply[2], name: regionNames[reply[2]] ?? "Unknown") }
            return nil
        }
        let region = reply[idx + 2]
        return RegionInfo(regionID: region, name: regionNames[region] ?? "Unknown")
    }

    /// Parse a `read_layout` reply: `[0xF2, err, layout_id]`. 0=US, 1=EU, 2=JP.
    public static func parseLayout(_ reply: [UInt8]) -> UInt8? {
        if let idx = reply.firstIndex(of: 0xF2), reply.count >= idx + 3 { return reply[idx + 2] }
        return reply.count >= 3 ? reply[2] : nil
    }
}
