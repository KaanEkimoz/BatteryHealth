import Foundation
import IOKit
import IOKit.ps

/// Snapshot of the AppleSmartBattery registry entry. Readable without root.
public struct BatterySnapshot: Codable, Equatable {
    public var percent: Int
    /// The gauge's own state of charge. The firmware charge range is compared
    /// against this, not against the (smoothed) percentage macOS displays;
    /// the two can differ by a few points.
    public var gaugePercent: Int?
    public var isCharging: Bool
    public var externalConnected: Bool
    public var fullyCharged: Bool
    public var cycleCount: Int
    public var designCapacity: Int        // mAh
    public var rawMaxCapacity: Int        // mAh, real full-charge capacity
    public var nominalCapacity: Int       // mAh
    public var temperatureC: Double
    public var voltageV: Double
    public var amperageA: Double          // negative = discharging
    public var adapterWatts: Int?
    public var timeRemainingMinutes: Int?
    public var notChargingReason: Int
    public var chargerInhibitReason: Int
    public var cellVoltagesMV: [Int]
    public var dailyMinSoc: Int?
    public var dailyMaxSoc: Int?
    /// PowerTelemetryData, watts. Adapter → system input, battery (+ charging,
    /// − discharging) and total system load.
    public var adapterInW: Double
    public var batteryW: Double
    public var systemLoadW: Double

    /// Gauge's current full-charge capacity relative to design capacity. Raw:
    /// it moves a few percent with temperature and charge level, and is not
    /// the number macOS shows (see MacOSBatteryHealth).
    public var healthPercent: Double {
        designCapacity > 0 ? Double(rawMaxCapacity) / Double(designCapacity) * 100 : 0
    }

    public var powerW: Double { voltageV * amperageA }

    /// Best-effort decoding of ChargerData.NotChargingReason bits seen on Apple silicon.
    public var notChargingDescription: String? {
        guard externalConnected, !isCharging else { return nil }
        if fullyCharged || percent >= 100 { return "Full" }
        // Bit 24 is set by any charge limit: the firmware range, macOS's own
        // limit or optimized charging.
        if notChargingReason & (1 << 24) != 0 { return "Held at charge limit" }
        if notChargingReason == 0 { return nil }
        return String(format: "Held (reason 0x%x)", notChargingReason)
    }

    public static func read() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }

        func int(_ d: [String: Any], _ k: String) -> Int? {
            guard let n = d[k] as? NSNumber else { return nil }
            return n.intValue
        }
        let charger = dict["ChargerData"] as? [String: Any] ?? [:]
        let data = dict["BatteryData"] as? [String: Any] ?? [:]
        let adapter = dict["AdapterDetails"] as? [String: Any] ?? [:]
        let time = int(dict, "TimeRemaining")
        let telemetry = dict["PowerTelemetryData"] as? [String: Any] ?? [:]
        /// Signed values arrive as unsigned 64-bit two's complement.
        func milliwatts(_ k: String) -> Double {
            guard let n = telemetry[k] as? NSNumber else { return 0 }
            return Double(Int64(bitPattern: n.uint64Value)) / 1000
        }

        return BatterySnapshot(
            percent: int(dict, "CurrentCapacity") ?? 0,
            gaugePercent: int(data, "StateOfCharge"),
            isCharging: dict["IsCharging"] as? Bool ?? false,
            externalConnected: dict["ExternalConnected"] as? Bool ?? false,
            fullyCharged: dict["FullyCharged"] as? Bool ?? false,
            cycleCount: int(dict, "CycleCount") ?? 0,
            designCapacity: int(dict, "DesignCapacity") ?? 0,
            rawMaxCapacity: int(dict, "AppleRawMaxCapacity") ?? 0,
            nominalCapacity: int(dict, "NominalChargeCapacity") ?? 0,
            temperatureC: Double(int(dict, "Temperature") ?? 0) / 100,
            voltageV: Double(int(dict, "Voltage") ?? 0) / 1000,
            amperageA: Double(Int64(bitPattern: (dict["Amperage"] as? NSNumber)?.uint64Value ?? 0)) / 1000,
            adapterWatts: int(adapter, "Watts"),
            timeRemainingMinutes: (time == nil || time! >= 65535) ? nil : time,
            notChargingReason: int(charger, "NotChargingReason") ?? 0,
            chargerInhibitReason: int(charger, "ChargerInhibitReason") ?? 0,
            cellVoltagesMV: (data["CellVoltage"] as? [NSNumber])?.map(\.intValue) ?? [],
            dailyMinSoc: int(data, "DailyMinSoc"),
            dailyMaxSoc: int(data, "DailyMaxSoc"),
            adapterInW: milliwatts("SystemPowerIn"),
            batteryW: milliwatts("BatteryPower"),
            systemLoadW: milliwatts("SystemLoad")
        )
    }
}
