import Foundation

/// How charging can be controlled on this Mac. Picked from the SMC keys that
/// actually exist, never from the macOS version: Apple ships new firmware to
/// old macOS releases too.
public enum ChargeBackend: String, Codable {
    /// `bfF0`/`bfD0`/`bfE0`: firmware enforces a lower/upper range itself,
    /// including while the Mac sleeps. Present on 20xxx firmware (M4 on
    /// macOS 26.7 / 15.8, early macOS 27 betas).
    case firmwareRange
    /// `CHTE` (Tahoe) or `CH0B`/`CH0C` (older): software toggles charging.
    case legacyInhibit
    case unsupported
}

public struct FirmwareRange: Codable, Equatable {
    public var active: Bool
    public var lower: Int
    public var upper: Int
}

public enum ChargeControlError: Error, CustomStringConvertible {
    case unsupported(String)
    case invalidRange(Int, Int)
    case verifyFailed(String)

    public var description: String {
        switch self {
        case .unsupported(let s): return s
        case .invalidRange(let l, let u): return "Invalid range \(l)–\(u)%"
        case .verifyFailed(let s): return "Write did not stick: \(s)"
        }
    }
}

public final class ChargeControl {
    public static let fwActivation = "bfF0"
    public static let fwUpper = "bfD0"
    public static let fwLower = "bfE0"

    public let smc: SMC
    public let backend: ChargeBackend
    /// Key that disconnects the power adapter (Mac runs on battery while plugged in).
    public let adapterKey: String?
    public let hasMagSafeLED: Bool

    public init(smc: SMC) {
        self.smc = smc
        if smc.hasKey(Self.fwActivation) && smc.hasKey(Self.fwUpper) && smc.hasKey(Self.fwLower) {
            backend = .firmwareRange
        } else if smc.hasKey("CHTE") || (smc.hasKey("CH0B") && smc.hasKey("CH0C")) {
            backend = .legacyInhibit
        } else {
            backend = .unsupported
        }
        if smc.hasKey("CHIE") { adapterKey = "CHIE" }
        else if smc.hasKey("CH0J") { adapterKey = "CH0J" }
        else if smc.hasKey("CH0I") { adapterKey = "CH0I" }
        else { adapterKey = nil }
        hasMagSafeLED = smc.hasKey("ACLC")
    }

    // MARK: Firmware range (bfF0 / bfD0 / bfE0)

    /// Percentages are stored as little-endian ui32 (50% == 32 00 00 00).
    private func readPercent(_ key: String) throws -> Int {
        let b = try smc.read(key)
        guard b.count == 4 else { throw SMCError.sizeMismatch(key, expected: 4, got: b.count) }
        return Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
    }

    private func writePercent(_ key: String, _ value: Int) throws {
        let v = UInt32(value)
        try smc.write(key, [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)])
    }

    public func readFirmwareRange() throws -> FirmwareRange {
        let act = try smc.read(Self.fwActivation)
        return FirmwareRange(active: act.first == 0x02,
                             lower: try readPercent(Self.fwLower),
                             upper: try readPercent(Self.fwUpper))
    }

    /// Writes the range only when it differs. The firmware requires the order:
    /// deactivate, upper, lower, activate. Returns true when something was written.
    @discardableResult
    public func ensureFirmwareRange(lower: Int, upper: Int) throws -> Bool {
        guard backend == .firmwareRange else { throw ChargeControlError.unsupported("Firmware range keys not present") }
        guard lower >= 0, upper <= 100, lower < upper else { throw ChargeControlError.invalidRange(lower, upper) }
        let want = FirmwareRange(active: true, lower: lower, upper: upper)
        if try readFirmwareRange() == want { return false }
        try smc.write(Self.fwActivation, [0x00])
        try writePercent(Self.fwUpper, upper)
        try writePercent(Self.fwLower, lower)
        try smc.write(Self.fwActivation, [0x02])
        let got = try readFirmwareRange()
        guard got == want else {
            throw ChargeControlError.verifyFailed("wanted \(lower)–\(upper)% active, read \(got.lower)–\(got.upper)% active=\(got.active)")
        }
        return true
    }

    @discardableResult
    public func disableFirmwareRange() throws -> Bool {
        guard backend == .firmwareRange else { return false }
        if try smc.read(Self.fwActivation).first == 0x00 { return false }
        try smc.write(Self.fwActivation, [0x00])
        return true
    }

    // MARK: Legacy inhibit (CHTE / CH0B+CH0C)

    public func setChargingInhibited(_ inhibited: Bool) throws {
        if smc.hasKey("CHTE") {
            try smc.write("CHTE", inhibited ? [0x01, 0, 0, 0] : [0, 0, 0, 0])
        } else if smc.hasKey("CH0B") {
            try smc.write("CH0B", [inhibited ? 0x02 : 0x00])
            try smc.write("CH0C", [inhibited ? 0x02 : 0x00])
        } else {
            throw ChargeControlError.unsupported("No charge-inhibit key")
        }
    }

    public func isChargingInhibited() -> Bool? {
        if let b = try? smc.read("CHTE") { return b.first != 0 }
        if let b = try? smc.read("CH0B") { return b.first != 0 }
        return nil
    }

    // MARK: Adapter (forced discharge)

    public func isAdapterCut() -> Bool? {
        guard let key = adapterKey, let b = try? smc.read(key) else { return nil }
        return b.first != 0
    }

    public func setAdapterCut(_ cut: Bool) throws {
        guard let key = adapterKey else { throw ChargeControlError.unsupported("No adapter-control key") }
        let on: UInt8 = key == "CHIE" ? 0x08 : 0x01
        if isAdapterCut() == cut { return }
        try smc.write(key, [cut ? on : 0x00])
    }

    // MARK: MagSafe LED (ACLC)

    public enum LED: UInt8 { case system = 0x00, off = 0x01, green = 0x03, orange = 0x04 }

    public func setMagSafeLED(_ led: LED) throws {
        guard hasMagSafeLED else { return }
        try smc.write("ACLC", [led.rawValue])
    }

    /// ACLC reads back the colour on screen, not the mode written (system mode
    /// reads as 03 when macOS shows green), so remember what we asked for.
    private var lastLED: LED?

    /// Writes when the mode changes, or when firmware drifted from an explicit
    /// colour we set. Returns true on write.
    @discardableResult
    public func ensureMagSafeLED(_ led: LED) throws -> Bool {
        guard hasMagSafeLED else { return false }
        if led == lastLED {
            if led == .system { return false }
            if try smc.read("ACLC").first == led.rawValue { return false }
        }
        try smc.write("ACLC", [led.rawValue])
        lastLED = led
        return true
    }

    /// Puts the machine back to stock charging behaviour.
    public func resetAll() {
        if backend == .firmwareRange { _ = try? disableFirmwareRange() }
        if backend == .legacyInhibit { try? setChargingInhibited(false) }
        try? setAdapterCut(false)
        try? setMagSafeLED(.system)
    }
}
