import Foundation

/// The "Maximum Capacity" and condition macOS shows in System Settings → Battery.
/// Apple computes this privately (it is smoothed and not the raw gauge value),
/// so it is read from system_profiler rather than derived from IOKit.
public struct MacOSBatteryHealth: Equatable {
    public var maximumCapacityPercent: Int?
    public var condition: String?

    public static func read() -> MacOSBatteryHealth? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPPowerDataType", "-json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for item in items {
            guard let info = item["sppower_battery_health_info"] as? [String: Any] else { continue }
            // Formatted per locale, e.g. "99%" or "%99".
            let raw = info["sppower_battery_health_maximum_capacity"] as? String ?? ""
            let digits = raw.filter(\.isNumber)
            return MacOSBatteryHealth(maximumCapacityPercent: Int(digits),
                                      condition: info["sppower_battery_health"] as? String)
        }
        return nil
    }
}

/// macOS's own charge limit (System Settings → Battery → Charging, 26.4+).
/// It's a second, independent gate: when both are on, macOS's hysteresis wins
/// and the battery can sit a few percent under our limit on the charger.
public enum MacOSChargeLimit {
    /// The manual limit macOS has registered, or nil when it's off. macOS
    /// withdraws it after a few minutes on battery, so this is only reliable
    /// while the charger is connected.
    public static func read() -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "battlimit"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard text.contains("manualChargeLimit") else { return nil }
        for line in text.split(separator: "\n") where line.contains("chargeSocLimitSoc") {
            if let n = Int(line.filter(\.isNumber)) { return n }
        }
        return nil
    }
}
