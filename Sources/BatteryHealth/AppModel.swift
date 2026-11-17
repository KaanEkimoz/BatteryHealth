import Foundation
import AppKit
import ServiceManagement
import BatteryKit

@MainActor
final class AppModel: ObservableObject {
    @Published var battery: BatterySnapshot?
    @Published var macOSHealth: MacOSBatteryHealth?
    /// macOS's own charge limit, when it's on (it conflicts with ours).
    @Published var macOSLimit: Int?
    private var macOSHealthReadAt = Date.distantPast
    @Published var daemon: DaemonStatus?
    @Published var daemonError: String?
    @Published var config = ChargeConfig()
    @Published var busy = false
    @Published var message: String?
    @Published var installed = Installer.isInstalled
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var uptime = Uptime.read()
    private let restartReminder = RestartReminder()
    @Published var restartReminderEnabled: Bool

    private let client = DaemonClient()
    private var timer: Timer?
    private var applyWork: DispatchWorkItem?
    /// While the user is editing, don't let a status poll overwrite their values.
    private var editingUntil = Date.distantPast

    init() {
        config = ChargeConfig.load()
        restartReminderEnabled = restartReminder.isEnabled
        if restartReminderEnabled { restartReminder.requestPermission() }
        // Debug aid: `open -a BatteryHealth --args --test-restart-reminder`.
        if CommandLine.arguments.contains("--test-restart-reminder") {
            let reminder = restartReminder
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated { reminder.post(days: 3) }
            }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var needsDaemonUpdate: Bool {
        guard let d = daemon else { return false }
        return d.daemonVersion != BatteryHealthIDs.daemonVersion
    }

    func refresh() {
        battery = BatterySnapshot.read()
        uptime = Uptime.read()
        restartReminder.check(uptime)
        // macOS updates its figure rarely; system_profiler is cheap but not free.
        if Date().timeIntervalSince(macOSHealthReadAt) > 600 {
            macOSHealthReadAt = Date()
            DispatchQueue.global(qos: .utility).async {
                let h = MacOSBatteryHealth.read()
                DispatchQueue.main.async { self.macOSHealth = h }
            }
        }
        if battery?.externalConnected == true {
            DispatchQueue.global(qos: .utility).async {
                let l = MacOSChargeLimit.read()
                DispatchQueue.main.async { self.macOSLimit = l }
            }
        }
        installed = Installer.isInstalled
        guard installed else { daemon = nil; return }
        client.status { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let s):
                self.daemon = s
                self.daemonError = nil
                if Date() > self.editingUntil { self.config = s.config }
            case .failure(let e):
                self.daemon = nil
                self.daemonError = e.localizedDescription
            }
        }
    }

    /// Debounced so dragging the slider sends one write.
    func update(_ change: (inout ChargeConfig) -> Void) {
        change(&config)
        editingUntil = Date().addingTimeInterval(3)
        applyWork?.cancel()
        let snapshot = config
        let work = DispatchWorkItem { [weak self] in
            self?.client.apply(snapshot) { error in
                self?.message = error
                self?.refresh()
            }
        }
        applyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func resetToStock() {
        client.reset { [weak self] error in
            self?.message = error ?? L("Stock macOS charging restored")
            self?.refresh()
        }
    }

    func installDaemon() { runAdmin { Installer.install() } }
    func uninstallDaemon() { runAdmin { Installer.uninstall() } }

    private func runAdmin(_ op: @escaping () -> String?) {
        busy = true
        client.invalidate()
        DispatchQueue.global().async {
            let err = op()
            DispatchQueue.main.async {
                self.busy = false
                self.message = err
                // Give launchd a moment to start the daemon.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
            }
        }
    }

    func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func setRestartReminder(_ on: Bool) {
        restartReminder.isEnabled = on
        restartReminderEnabled = on
        if on { restartReminder.check(uptime) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = L("Login item: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
