import Foundation
import UserNotifications

/// Time since the Mac last started (sleep included, as macOS counts it).
struct Uptime {
    let bootDate: Date
    var interval: TimeInterval { Date().timeIntervalSince(bootDate) }
    var hours: Int { Int(interval / 3600) }

    static func read() -> Uptime? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Uptime(bootDate: Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1e6))
    }

    /// "1 h 12 m" under a day, "52 h" under three days, "3 d 4 h" after.
    var shortText: String {
        let h = hours
        if h < 24 { return "\(h) h \(Int(interval / 60) % 60) m" }
        return h < 72 ? "\(h) h" : "\(h / 24) d \(h % 24) h"
    }
}

/// Posts "time to restart" once the Mac has been up longer than `threshold`,
/// then at most once a day until it restarts.
@MainActor
final class RestartReminder {
    static let thresholdHours = 72
    private let defaults = UserDefaults.standard
    private let enabledKey = "restartReminderEnabled"
    private let lastKey = "restartReminderLastSent"
    private let bootKey = "restartReminderBoot"

    var isEnabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: enabledKey)
            if newValue { requestPermission() }
        }
    }

    /// UNUserNotificationCenter traps outside an .app bundle (e.g. `swift run`).
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    func requestPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func check(_ uptime: Uptime?) {
        guard canNotify, isEnabled, let uptime, uptime.hours >= Self.thresholdHours else { return }
        let boot = uptime.bootDate.timeIntervalSince1970
        let last = defaults.double(forKey: lastKey)
        let sameBoot = abs(defaults.double(forKey: bootKey) - boot) < 60
        if sameBoot && Date().timeIntervalSince1970 - last < 24 * 3600 { return }

        post(days: uptime.hours / 24)
        defaults.set(Date().timeIntervalSince1970, forKey: lastKey)
        defaults.set(boot, forKey: bootKey)
    }

    /// e.g. "Mac 3 gündür açık" / "Yeniden başlatma öneriliyor."
    func post(days: Int) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = "Mac \(days) gündür açık"
        content.body = "Yeniden başlatma öneriliyor."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "restart-reminder", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
