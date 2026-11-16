import Foundation

public enum BatteryHealthIDs {
    public static let daemonLabel = "com.kaanusta.batteryhealth.daemon"
    public static let machService = "com.kaanusta.batteryhealth.daemon.xpc"
    public static let daemonPath = "/Library/PrivilegedHelperTools/com.kaanusta.batteryhealth.daemon"
    public static let plistPath = "/Library/LaunchDaemons/com.kaanusta.batteryhealth.daemon.plist"
    public static let configDir = "/Library/Application Support/BatteryHealth"
    public static let configPath = configDir + "/config.json"
    public static let logPath = "/var/log/batteryhealthd.log"
    /// Bumped whenever the daemon's behaviour or protocol changes, so the app
    /// can offer to reinstall it.
    public static let daemonVersion = 2
}

public struct ChargeConfig: Codable, Equatable {
    /// Master switch. Off = stock macOS charging.
    public var limitEnabled = true
    /// Charging stops here.
    public var upperLimit = 80
    /// Charging restarts once the battery has dropped this far below the upper
    /// limit. 1 = hold at the limit (firmware range limit-1…limit).
    public var restartGap = 1
    /// Stop charging while the battery is hotter than `heatLimitC`.
    public var heatProtection = true
    public var heatLimitC = 35.0
    /// One-shot: charge to 100% (e.g. before a trip), then go back to the limit
    /// once the charger is unplugged.
    public var topUpToFull = false
    /// One-shot: cut the adapter until the battery is down to the upper limit.
    public var dischargeToLimit = false

    /// MagSafe LED: green while held at the limit, orange while charging or discharging.
    public var controlMagSafeLED = true

    public init() {}

    // Tolerant decoding so configs written by older versions keep working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChargeConfig()
        limitEnabled = try c.decodeIfPresent(Bool.self, forKey: .limitEnabled) ?? d.limitEnabled
        upperLimit = try c.decodeIfPresent(Int.self, forKey: .upperLimit) ?? d.upperLimit
        restartGap = try c.decodeIfPresent(Int.self, forKey: .restartGap) ?? d.restartGap
        heatProtection = try c.decodeIfPresent(Bool.self, forKey: .heatProtection) ?? d.heatProtection
        heatLimitC = try c.decodeIfPresent(Double.self, forKey: .heatLimitC) ?? d.heatLimitC
        topUpToFull = try c.decodeIfPresent(Bool.self, forKey: .topUpToFull) ?? d.topUpToFull
        dischargeToLimit = try c.decodeIfPresent(Bool.self, forKey: .dischargeToLimit) ?? d.dischargeToLimit
        controlMagSafeLED = try c.decodeIfPresent(Bool.self, forKey: .controlMagSafeLED) ?? d.controlMagSafeLED
    }

    public var holdsAtLimit: Bool { restartGap <= 1 }

    public var lowerLimit: Int { max(5, min(upperLimit - 1, upperLimit - restartGap)) }

    /// Firmware range for "hold at the limit". The firmware compares against
    /// the gauge's own state of charge (macOS may display it a point higher).
    /// One narrow range both stops a charge and ends a drain there.
    public func firmwareBounds(gaugeTarget: Int) -> (lower: Int, upper: Int) {
        guard holdsAtLimit else { return (lowerLimit, upperLimit) }
        let t = min(100, max(6, gaugeTarget))  // caller keeps it within limit-4…limit
        return (t - 1, t)
    }

    public static let limitRange = 70...100

    public func sanitized() -> ChargeConfig {
        var c = self
        c.upperLimit = min(Self.limitRange.upperBound, max(Self.limitRange.lowerBound, c.upperLimit))
        c.restartGap = min(20, max(1, c.restartGap))
        c.heatLimitC = min(45, max(30, c.heatLimitC))
        return c
    }

    public static func load(from path: String = BatteryHealthIDs.configPath) -> ChargeConfig {
        guard let data = FileManager.default.contents(atPath: path),
              let c = try? JSONDecoder().decode(ChargeConfig.self, from: data) else { return ChargeConfig() }
        return c.sanitized()
    }

    public func save(to path: String = BatteryHealthIDs.configPath) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// What the daemon reports back to the app.
public struct DaemonStatus: Codable {
    public var daemonVersion: Int
    public var backend: ChargeBackend
    public var adapterKey: String?
    public var config: ChargeConfig
    public var firmwareRange: FirmwareRange?
    public var adapterCut: Bool?
    public var heatHold: Bool
    /// Human-readable summary of what the daemon is doing right now.
    public var state: String
    public var lastError: String?
    public var lastReconcile: Date

    public init(daemonVersion: Int, backend: ChargeBackend, adapterKey: String?, config: ChargeConfig,
                firmwareRange: FirmwareRange?, adapterCut: Bool?, heatHold: Bool, state: String,
                lastError: String?, lastReconcile: Date) {
        self.daemonVersion = daemonVersion; self.backend = backend; self.adapterKey = adapterKey
        self.config = config; self.firmwareRange = firmwareRange; self.adapterCut = adapterCut
        self.heatHold = heatHold; self.state = state; self.lastError = lastError; self.lastReconcile = lastReconcile
    }
}

/// XPC interface. Payloads are JSON so the protocol stays trivially versionable.
@objc(BatteryDaemonProtocol)
public protocol BatteryDaemonProtocol {
    func status(reply: @escaping (Data?) -> Void)
    /// JSON-encoded ChargeConfig. Replies with an error string or nil.
    func apply(config: Data, reply: @escaping (String?) -> Void)
    /// Restore stock charging and stop enforcing until a new config is applied.
    func reset(reply: @escaping (String?) -> Void)
}
