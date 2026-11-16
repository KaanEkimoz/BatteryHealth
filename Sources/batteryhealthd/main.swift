import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import BatteryKit

// MARK: - XPC service

final class Service: NSObject, BatteryDaemonProtocol, NSXPCListenerDelegate {
    let controller: Controller
    init(controller: Controller) { self.controller = controller }

    /// Only root and members of the admin group may change charging.
    private func isAuthorized(uid: uid_t) -> Bool {
        if uid == 0 { return true }
        guard let pw = getpwuid(uid) else { return false }
        var count: Int32 = 64
        var groups = [Int32](repeating: 0, count: Int(count))
        guard getgrouplist(pw.pointee.pw_name, Int32(pw.pointee.pw_gid), &groups, &count) != -1 else { return false }
        return groups.prefix(Int(count)).contains(80) // admin
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        guard isAuthorized(uid: c.effectiveUserIdentifier) else {
            log("rejected XPC connection from uid \(c.effectiveUserIdentifier)")
            return false
        }
        c.exportedInterface = NSXPCInterface(with: BatteryDaemonProtocol.self)
        c.exportedObject = self
        c.resume()
        return true
    }

    func status(reply: @escaping (Data?) -> Void) {
        controller.queue.async {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            reply(try? enc.encode(self.controller.status()))
        }
    }

    func apply(config: Data, reply: @escaping (String?) -> Void) {
        controller.queue.async {
            do {
                let c = try JSONDecoder().decode(ChargeConfig.self, from: config)
                try self.controller.apply(c)
                reply(nil)
            } catch {
                reply("\(error)")
            }
        }
    }

    func reset(reply: @escaping (String?) -> Void) {
        controller.queue.async {
            self.controller.reset()
            reply(nil)
        }
    }
}

// MARK: - System events

var rootPort: io_connect_t = 0
var notifier: io_object_t = 0
var gController: Controller!

func registerSleepWake() {
    var portRef: IONotificationPortRef?
    rootPort = IORegisterForSystemPower(nil, &portRef, { _, _, messageType, argument in
        switch messageType {
        case 0xE000_0270: // kIOMessageCanSystemSleep
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case 0xE000_0280: // kIOMessageSystemWillSleep
            gController.queue.sync { gController.prepareForSleep() }
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case 0xE000_0300: // kIOMessageSystemHasPoweredOn
            gController.queue.asyncAfter(deadline: .now() + 2) { gController.reconcile(reason: "wake") }
        default: break
        }
    }, &notifier)
    if let portRef {
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(portRef).takeUnretainedValue(), .defaultMode)
    }
}

func registerPowerSourceChanges() {
    if let src = IOPSNotificationCreateRunLoopSource({ _ in
        gController.queue.async { gController.reconcile(reason: "power") }
    }, nil)?.takeRetainedValue() {
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }
}

func runDaemon() -> Never {
    guard getuid() == 0 else { fail("daemon must run as root (it is started by launchd)") }
    do { gController = try Controller() } catch { fail("\(error)") }

    let service = Service(controller: gController)
    let listener = NSXPCListener(machServiceName: BatteryHealthIDs.machService)
    listener.delegate = service
    listener.resume()

    registerSleepWake()
    registerPowerSourceChanges()

    let timer = DispatchSource.makeTimerSource(queue: gController.queue)
    timer.schedule(deadline: .now(), repeating: 30, leeway: .seconds(5))
    timer.setEventHandler { gController.reconcile(reason: "timer") }
    timer.resume()

    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: sig, queue: gController.queue)
        s.setEventHandler { gController.shutdown(); exit(0) }
        s.resume()
        signalSources.append(s)
    }
    withExtendedLifetime((service, listener, timer)) { RunLoop.main.run() }
    exit(0)
}
var signalSources: [DispatchSourceSignal] = []

// MARK: - CLI

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("error: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

func requireRoot() {
    if getuid() != 0 { fail("this command changes charging and must be run with sudo") }
}

func printStatus(json: Bool) {
    let smc: SMC
    do { smc = try SMC() } catch { fail("\(error)") }
    let control = ChargeControl(smc: smc)
    let b = BatterySnapshot.read()
    let cfg = ChargeConfig.load()
    let range = control.backend == .firmwareRange ? try? control.readFirmwareRange() : nil
    if json {
        struct Out: Encodable { let battery: BatterySnapshot?; let backend: ChargeBackend; let firmwareRange: FirmwareRange?; let config: ChargeConfig; let adapterCut: Bool? }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! enc.encode(Out(battery: b, backend: control.backend, firmwareRange: range, config: cfg, adapterCut: control.isAdapterCut()))
        print(String(data: data, encoding: .utf8)!)
        return
    }
    print("Backend:        \(control.backend.rawValue)  (adapter key: \(control.adapterKey ?? "none"))")
    if let r = range { print("Firmware range: \(r.active ? "ACTIVE" : "inactive")  \(r.lower)–\(r.upper)%") }
    if let cut = control.isAdapterCut() { print("Adapter cut:    \(cut)") }
    print("Power:          adapter \(String(format: "%.1f", b?.adapterInW ?? 0)) W, battery \(String(format: "%+.1f", b?.batteryW ?? 0)) W, system \(String(format: "%.1f", b?.systemLoadW ?? 0)) W")
    print("Config:         limit \(cfg.upperLimit)%\(cfg.limitEnabled ? (cfg.holdsAtLimit ? " (hold)" : " (resume at \(cfg.lowerLimit)%)") : " off"), heat \(cfg.heatProtection ? "\(Int(cfg.heatLimitC))°C" : "off"), topUp \(cfg.topUpToFull), discharge \(cfg.dischargeToLimit)")
    if let b {
        print("Battery:        \(b.percent)% (gauge \(b.gaugePercent.map(String.init) ?? "?")%)  \(b.isCharging ? "charging" : "not charging")  \(b.externalConnected ? "on AC" : "on battery")")
        if let h = MacOSBatteryHealth.read(), let pct = h.maximumCapacityPercent {
            print("Health (macOS): \(pct)%  \(h.condition ?? "")")
        }
        print("Measured:       \(String(format: "%.1f", b.healthPercent))%  (\(b.rawMaxCapacity)/\(b.designCapacity) mAh raw gauge), \(b.cycleCount) cycles")
        print("Temperature:    \(String(format: "%.1f", b.temperatureC))°C   Power: \(String(format: "%.1f", b.powerW)) W")
        if let r = b.notChargingDescription { print("Not charging:   \(r)") }
    }
}

/// Without sudo, hand the change to the running daemon over XPC (admin users only).
func modifyViaDaemon(_ change: (inout ChargeConfig) -> Void) -> Never {
    let conn = NSXPCConnection(machServiceName: BatteryHealthIDs.machService, options: .privileged)
    conn.remoteObjectInterface = NSXPCInterface(with: BatteryDaemonProtocol.self)
    conn.resume()
    let done = DispatchSemaphore(value: 0)
    var failure: String?
    let proxy = conn.remoteObjectProxyWithErrorHandler { e in failure = e.localizedDescription; done.signal() } as? BatteryDaemonProtocol
    var c = ChargeConfig.load()
    change(&c)
    guard let data = try? JSONEncoder().encode(c), let proxy else { fail("daemon unavailable") }
    proxy.apply(config: data) { err in failure = err; done.signal() }
    if done.wait(timeout: .now() + 10) == .timedOut { fail("daemon did not answer (is it installed?)") }
    if let failure { fail(failure) }
    print("Applied: limit \(c.limitEnabled ? "\(c.upperLimit)%\(c.holdsAtLimit ? " (hold)" : " (resume at \(c.lowerLimit)%)")" : "off")")
    exit(0)
}

func modifyConfig(_ change: (inout ChargeConfig) -> Void) {
    if getuid() != 0 { modifyViaDaemon(change) }
    var c = ChargeConfig.load()
    change(&c)
    do {
        let ctl = try Controller()
        try ctl.queue.sync { try ctl.apply(c) }
        print(ctl.queue.sync { ctl.status().state })
    } catch { fail("\(error)") }
}

let usage = """
batteryhealthd – battery charge limiter for Apple silicon Macs

  status [--json]        show battery, backend and limiter state (no sudo needed)
  keys                   list charge-related SMC keys on this Mac
  set <upper> [gap]      limit charging to <upper>% (gap 1 = hold at limit, default)
  gap <n>                resume charging n% below the limit (1 = hold at limit)
  on | off               enable / disable the limiter
  topup                  charge to 100% once; limit returns after unplugging
  discharge              run from battery while plugged in until down to the limit
  heat <°C> | heat off   pause charging above this battery temperature
  led on | off           MagSafe LED: green at limit, orange while charging
  (config commands go through the daemon; with sudo they also work without it)
  reset                  turn limiter off and restore stock keys                                [sudo]
  daemon                 run the daemon (used by launchd)
"""

var args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "" {
case "daemon":
    runDaemon()
case "status":
    printStatus(json: args.contains("--json"))
case "keys":
    let smc = (try? SMC()) ?? { fail("cannot open SMC") }()
    let keys = (try? smc.allKeys()) ?? []
    for k in keys where k.hasPrefix("CH") || k.hasPrefix("bf") || k.hasPrefix("AC") || k == "BUIC" {
        let info = try? smc.keyInfo(k)
        let val: String
        do { val = try smc.read(k).map { String(format: "%02x", $0) }.joined(separator: " ") }
        catch { val = "(\(error))" }
        print("\(k)  \(info?.type ?? "?")  \(info?.size ?? 0)  \(val)")
    }
case "set":
    guard args.count >= 2, let upper = Int(args[1]) else { fail("usage: set <upper> [gap]") }
    let gap = args.count >= 3 ? Int(args[2]) : nil
    modifyConfig { $0.limitEnabled = true; $0.upperLimit = upper; if let gap { $0.restartGap = gap } }
case "gap":
    guard args.count >= 2, let g = Int(args[1]) else { fail("usage: gap <n>") }
    modifyConfig { $0.restartGap = g }
case "led":
    guard args.count >= 2, ["on", "off"].contains(args[1]) else { fail("usage: led on|off") }
    modifyConfig { $0.controlMagSafeLED = args[1] == "on" }
case "on":  modifyConfig { $0.limitEnabled = true }
case "off": modifyConfig { $0.limitEnabled = false }
case "topup": modifyConfig { $0.topUpToFull = true; $0.dischargeToLimit = false }
case "discharge": modifyConfig { $0.dischargeToLimit = true; $0.topUpToFull = false }
case "heat":
    guard args.count >= 2 else { fail("usage: heat <°C> | heat off") }
    if args[1] == "off" { modifyConfig { $0.heatProtection = false } }
    else if let t = Double(args[1]) { modifyConfig { $0.heatProtection = true; $0.heatLimitC = t } }
    else { fail("usage: heat <°C> | heat off") }
case "reset":
    requireRoot()
    do { let ctl = try Controller(); ctl.queue.sync { ctl.reset() }; print("Limiter off, stock macOS charging restored. Run 'on' to enable it again.") }
    catch { fail("\(error)") }
default:
    print(usage)
}
