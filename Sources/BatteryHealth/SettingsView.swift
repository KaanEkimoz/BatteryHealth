import SwiftUI
import BatteryKit

/// Settings, pushed inside the menu bar panel like a Control Center sub-page:
/// grouped rows, one level deep, back chevron at the top-left.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gap) {
            header

            SettingsGroup("General") {
                ToggleRow(title: "Open at Login",
                          isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Divider().padding(.leading, 12)
                ToggleRow(title: "Restart Reminder",
                          subtitle: "Notify after \(RestartReminder.thresholdHours) hours on",
                          isOn: Binding(get: { model.restartReminderEnabled }, set: { model.setRestartReminder($0) }))
            }

            if model.installed {
                SettingsGroup("Charging") {
                    ToggleRow(title: "MagSafe LED Shows Limit",
                              subtitle: "Green when held, orange when moving",
                              isOn: binding(\.controlMagSafeLED))
                    Divider().padding(.leading, 12)
                    HStack {
                        Text("Heat Guard Limit")
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: binding(\.heatLimitC)) {
                            Text("35°").tag(35.0)
                            Text("38°").tag(38.0)
                            Text("40°").tag(40.0)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }

            SettingsGroup("Charge Control",
                          footer: "A small background service writes your limit to the battery firmware, so it keeps working while the Mac sleeps or this app is closed. Setting it up asks for your password once.") {
                HStack(spacing: 6) {
                    Circle().fill(helperColor).frame(width: 6, height: 6)
                    Text(helperText).font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                Divider().padding(.leading, 12)
                if model.installed {
                    ActionRow(title: "Turn Off and Use macOS Charging") { model.resetToStock() }
                    Divider().padding(.leading, 12)
                    ActionRow(title: model.needsDaemonUpdate ? "Update Charge Control…" : "Repair Charge Control…") { model.installDaemon() }
                    Divider().padding(.leading, 12)
                    ActionRow(title: "Remove Charge Control…", role: .destructive) { model.uninstallDaemon() }
                } else {
                    ActionRow(title: "Set Up Charge Control…") { model.installDaemon() }
                }
            }

            HStack {
                Text("BatteryHealth \(version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                    .controlSize(.small)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("Back").font(.system(size: 12))
                }
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .keyboardShortcut(.cancelAction)
            Spacer()
        }
        .overlay {
            Text("Settings").font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private var helperColor: Color {
        guard model.daemon != nil else { return model.installed ? .orange : .secondary }
        return model.needsDaemonUpdate || model.daemon?.lastError != nil ? .orange : .green
    }

    private var helperText: String {
        guard model.installed else { return "Not set up" }
        guard model.daemon != nil else { return "Not responding" }
        if model.needsDaemonUpdate { return "Update available" }
        return "Active"
    }

    private func binding<T>(_ kp: WritableKeyPath<ChargeConfig, T>) -> Binding<T> {
        Binding(get: { model.config[keyPath: kp] }, set: { v in model.update { $0[keyPath: kp] = v } })
    }
}

/// A titled group of rows in one module, like a grouped list in System Settings.
private struct SettingsGroup<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            VStack(spacing: 0) { content }
                .background(
                    RoundedRectangle(cornerRadius: Metrics.module, style: .continuous)
                        .fill(.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.module, style: .continuous)
                        .strokeBorder(.primary.opacity(0.05), lineWidth: 0.5)
                )
            if let footer {
                Text(footer)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
            }
        }
    }
}

private struct ToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                if let subtitle {
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ActionRow: View {
    let title: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
    }
}

/// Highlight the row while it's held down, like a list row.
private struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
    }
}
