import Foundation
import IOKit.pwr_mgt
import BatteryKit

func log(_ msg: String) {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    print("\(f.string(from: Date())) \(msg)")
    fflush(stdout)
}

/// Owns all SMC writes. Every method runs on `queue`.
final class Controller {
    let queue = DispatchQueue(label: "batteryhealthd.controller")
    let control: ChargeControl
    private(set) var config = ChargeConfig()
    private var heatHold = false
    private var lastError: String?
    private var lastState = ""
    private var lastReconcile = Date.distantPast
    private var sleepAssertion: IOPMAssertionID = 0
    /// Hold mode: the gauge SOC the firmware is told to stop at, steered so that
    /// macOS *displays* the limit (the display runs a point or few above the gauge).
    private var holdGauge: Int?
    private var offTargetSince: Date?
    private var offTargetDirection = 0

    init() throws {
        control = ChargeControl(smc: try SMC())
        config = ChargeConfig.load()
        log("backend=\(control.backend.rawValue) adapterKey=\(control.adapterKey ?? "-") config=\(describe(config))")
    }

    private func describe(_ c: ChargeConfig) -> String {
        "limit=\(c.limitEnabled ? "\(c.upperLimit)%\(c.holdsAtLimit ? " hold" : " resume \(c.lowerLimit)%")" : "off") led=\(c.controlMagSafeLED) heat=\(c.heatProtection ? "\(Int(c.heatLimitC))C" : "off") topUp=\(c.topUpToFull) discharge=\(c.dischargeToLimit)"
    }

    // MARK: Public entry points (call on queue)

    func apply(_ newConfig: ChargeConfig) throws {
        let c = newConfig.sanitized()
        try c.save()
        log("config: \(describe(c))")
        config = c
        reconcile(reason: "config")
        if let e = lastError { throw ChargeControlError.verifyFailed(e) }
    }

    /// Turns the limiter off (persisted) and puts every key back to stock.
    func reset() {
        config.limitEnabled = false
        config.topUpToFull = false
        config.dischargeToLimit = false
        try? config.save()
        setDischarge(false)
        control.resetAll()
        heatHold = false
        lastState = "Stock macOS charging (reset)"
        log("reset: stock charging restored")
    }

    func status() -> DaemonStatus {
        DaemonStatus(daemonVersion: BatteryHealthIDs.daemonVersion,
                     backend: control.backend,
                     adapterKey: control.adapterKey,
                     config: config,
                     firmwareRange: control.backend == .firmwareRange ? try? control.readFirmwareRange() : nil,
                     adapterCut: control.isAdapterCut(),
                     heatHold: heatHold,
                     state: lastState,
                     lastError: lastError,
                     lastReconcile: lastReconcile)
    }

    /// Called before sleep: never leave the adapter cut, and on the legacy
    /// backend pause charging so it can't overshoot while no polls run.
    func prepareForSleep() {
        setDischarge(false)
        if control.backend == .legacyInhibit, config.limitEnabled, !config.topUpToFull,
           let b = BatterySnapshot.read(), b.percent >= config.lowerLimit {
            try? control.setChargingInhibited(true)
        }
    }

    func shutdown() {
        setDischarge(false)
        try? control.setMagSafeLED(.system)
        if control.backend == .legacyInhibit { try? control.setChargingInhibited(false) }
        // The firmware range is deliberately left active: it keeps protecting
        // the battery even while the daemon is not running.
        log("shutdown")
    }

    // MARK: Reconcile

    func reconcile(reason: String) {
        lastReconcile = Date()
        let disk = ChargeConfig.load()
        if disk != config { config = disk }
        guard let b = BatterySnapshot.read() else { record(state: "No battery found", error: nil); return }

        // One-shot flags end with the AC session / once reached.
        var changed = false
        if config.topUpToFull && !b.externalConnected { config.topUpToFull = false; changed = true }
        if config.dischargeToLimit && (!b.externalConnected || b.percent <= config.upperLimit) {
            config.dischargeToLimit = false; changed = true
        }
        if changed { try? config.save() }

        // Heat protection with 2 °C hysteresis.
        if config.heatProtection && b.externalConnected && b.temperatureC >= config.heatLimitC {
            if !heatHold { log("heat hold on at \(b.temperatureC)C") }
            heatHold = true
        } else if heatHold && (b.temperatureC <= config.heatLimitC - 2 || !b.externalConnected || !config.heatProtection) {
            log("heat hold off at \(b.temperatureC)C")
            heatHold = false
        }

        var state = ""
        var error: String?
        do {
            switch control.backend {
            case .firmwareRange: state = try reconcileFirmware(b)
            case .legacyInhibit: state = try reconcileLegacy(b)
            case .unsupported: state = "This Mac's firmware exposes no charge-control keys"
            }
        } catch let e {
            error = "\(e)"
        }

        let wantDischarge = config.dischargeToLimit && config.limitEnabled
        if let e = setDischarge(wantDischarge) { error = [error, e].compactMap { $0 }.joined(separator: "; ") }
        if wantDischarge { state = "Discharging to \(config.upperLimit)% (adapter cut)" }
        updateLED(b, discharging: wantDischarge)

        record(state: state, error: error)
    }

    /// Exact hold at the limit on firmware that only offers a gauge-based range:
    /// 1. While charging, the moment macOS displays the limit, freeze the range
    ///    at the current gauge value so the charge stops right there.
    /// 2. While resting on the charger, if the display has sat off the limit
    ///    for 15 minutes, nudge the gauge target one point. The display lags the
    ///    gauge by minutes, so it is never corrected while power is flowing.
    /// The target always stays within limit-4 … limit.
    private func steerHoldGauge(_ b: BatterySnapshot) -> Int {
        let limit = config.upperLimit
        let floor = max(6, limit - 4)
        var target = min(limit, max(floor, holdGauge ?? limit))
        defer { holdGauge = target }
        guard b.externalConnected, let gauge = b.gaugePercent else {
            offTargetSince = nil
            return target
        }

        if b.isCharging && b.percent >= limit && gauge < target {
            target = max(floor, gauge)
            offTargetSince = nil
            log("display reached \(b.percent)% – freezing at gauge \(target)%")
            return target
        }

        let resting = !b.isCharging && abs(b.batteryW) < 0.5
        let direction = b.percent > limit ? -1 : b.percent < limit ? 1 : 0
        guard resting, direction != 0 else {
            if direction == 0 || !resting { offTargetSince = nil }
            return target
        }
        if offTargetSince == nil || offTargetDirection != direction {
            offTargetSince = Date()
            offTargetDirection = direction
            return target
        }
        if Date().timeIntervalSince(offTargetSince!) >= 15 * 60 {
            let next = min(limit, max(floor, target + direction))
            if next != target {
                log("display steady at \(b.percent)% (gauge \(gauge)%) – gauge target \(target) → \(next)")
                target = next
            }
            offTargetSince = Date()
        }
        return target
    }

    /// Green = held at the limit, orange = moving toward it (charging or
    /// discharging). Unplugged, limiter off or LED control off: hand back to macOS.
    private func updateLED(_ b: BatterySnapshot, discharging: Bool) {
        guard control.hasMagSafeLED else { return }
        let led: ChargeControl.LED
        if !config.controlMagSafeLED || !config.limitEnabled || !b.externalConnected || config.topUpToFull {
            led = .system
        } else if discharging || b.isCharging || b.amperageA < -0.3 {
            // Charging, our forced discharge, or the firmware running the Mac
            // from the battery while it settles down to the limit.
            led = .orange
        } else {
            led = .green
        }
        do {
            if try control.ensureMagSafeLED(led) { log("MagSafe LED -> \(led)") }
        } catch {
            // Cosmetic; never let it mask a charging error.
        }
    }

    private func reconcileFirmware(_ b: BatterySnapshot) throws -> String {
        if !config.limitEnabled || config.upperLimit >= 100 {
            if try control.disableFirmwareRange() { log("firmware range disabled") }
            return "No limit – macOS charges normally"
        }
        if config.topUpToFull {
            if try control.disableFirmwareRange() { log("top-up: firmware range disabled") }
            return b.percent >= 100 ? "Topped up to 100% – limit returns when unplugged" : "Topping up to 100%"
        }
        var (lower, upper) = config.holdsAtLimit
            ? config.firmwareBounds(gaugeTarget: steerHoldGauge(b))
            : config.firmwareBounds(gaugeTarget: config.upperLimit)
        if heatHold {
            // Hold at the current level: lower < percent <= upper stops charging.
            upper = min(upper, max(6, b.percent))
            lower = max(5, upper - 1)
        }
        if try control.ensureFirmwareRange(lower: lower, upper: upper) {
            log("firmware range set \(lower)-\(upper)% (\(heatHold ? "heat hold" : "limit"))")
        }
        if heatHold { return "Paused: battery \(String(format: "%.1f", b.temperatureC))°C" }
        if !b.externalConnected { return "Limit \(config.upperLimit)% armed (on battery)" }
        let target = config.upperLimit
        if b.isCharging { return "Charging to \(target)%" }
        let level = b.percent
        if level > target { return "Above limit – settling to \(target)%" }
        if config.holdsAtLimit ? level >= target - 1 : level >= lower {
            return config.holdsAtLimit ? "Holding at \(target)%" : "Holding at limit (\(lower)–\(upper)%)"
        }
        return "Waiting to charge"
    }

    private func reconcileLegacy(_ b: BatterySnapshot) throws -> String {
        if !config.limitEnabled || config.upperLimit >= 100 || config.topUpToFull {
            try control.setChargingInhibited(false)
            return config.topUpToFull ? "Topping up to 100%" : "No limit – macOS charges normally"
        }
        let inhibited = control.isChargingInhibited() ?? false
        if heatHold || b.percent >= config.upperLimit {
            if !inhibited { try control.setChargingInhibited(true); log("charging inhibited at \(b.percent)%") }
            return heatHold ? "Paused: battery \(String(format: "%.1f", b.temperatureC))°C" : "Holding at \(config.upperLimit)%"
        }
        if b.percent <= config.lowerLimit || !b.externalConnected {
            if inhibited { try control.setChargingInhibited(false); log("charging allowed at \(b.percent)%") }
            return b.externalConnected ? "Charging to \(config.upperLimit)%" : "Limit \(config.upperLimit)% armed (on battery)"
        }
        return inhibited ? "Holding (\(config.lowerLimit)–\(config.upperLimit)%)" : "Charging to \(config.upperLimit)%"
    }

    @discardableResult
    private func setDischarge(_ on: Bool) -> String? {
        guard control.adapterKey != nil else { return on ? "This Mac has no adapter-control key" : nil }
        var failure: String?
        do {
            if control.isAdapterCut() != on {
                try control.setAdapterCut(on)
                log(on ? "adapter cut (discharging)" : "adapter restored")
            }
        } catch {
            failure = "Adapter: \(error)"
        }
        if on && sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "BatteryHealth discharging to limit" as CFString, &sleepAssertion)
        } else if !on && sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
        return failure
    }

    private func record(state: String, error: String?) {
        if state != lastState { log("state: \(state)") }
        if let error, error != lastError { log("error: \(error)") }
        lastState = state
        lastError = error
    }
}
