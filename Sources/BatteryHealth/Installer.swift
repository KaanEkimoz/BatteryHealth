import Foundation
import BatteryKit

/// Installs / removes the root daemon with a single macOS admin prompt.
enum Installer {
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: BatteryHealthIDs.daemonPath) &&
            FileManager.default.fileExists(atPath: BatteryHealthIDs.plistPath)
    }

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func install() -> String? {
        guard let res = Bundle.main.resourcePath else { return "No app bundle" }
        let daemon = res + "/batteryhealthd"
        let plist = res + "/\(BatteryHealthIDs.daemonLabel).plist"
        guard FileManager.default.fileExists(atPath: daemon), FileManager.default.fileExists(atPath: plist) else {
            return "Daemon files are missing from the app bundle – build with scripts/build.sh"
        }
        let label = BatteryHealthIDs.daemonLabel
        let script = """
        set -e
        launchctl bootout system/\(label) 2>/dev/null || true
        install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
        install -o root -g wheel -m 755 \(q(daemon)) \(q(BatteryHealthIDs.daemonPath))
        install -o root -g wheel -m 644 \(q(plist)) \(q(BatteryHealthIDs.plistPath))
        install -d -o root -g wheel -m 755 \(q(BatteryHealthIDs.configDir))
        launchctl bootstrap system \(q(BatteryHealthIDs.plistPath))
        """
        return runAsAdmin(script, prompt: "BatteryHealth wants to set up charge control.")
    }

    static func uninstall() -> String? {
        let label = BatteryHealthIDs.daemonLabel
        let script = """
        \(q(BatteryHealthIDs.daemonPath)) reset >/dev/null 2>&1 || true
        launchctl bootout system/\(label) 2>/dev/null || true
        rm -f \(q(BatteryHealthIDs.plistPath)) \(q(BatteryHealthIDs.daemonPath))
        """
        return runAsAdmin(script, prompt: "BatteryHealth wants to remove charge control.")
    }

    private static func runAsAdmin(_ shell: String, prompt: String) -> String? {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"\(prompt)\""
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err {
            if (err[NSAppleScript.errorNumber] as? Int) == -128 { return "Cancelled" }
            return err[NSAppleScript.errorMessage] as? String ?? "Admin script failed"
        }
        return nil
    }
}
