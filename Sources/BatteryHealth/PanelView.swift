import SwiftUI
import BatteryKit

// Control Center–style panel: grouped modules on the menu bar material,
// one hero number, direct-manipulation limit slider, round quick toggles.

enum Metrics {
    static let width: CGFloat = 316
    static let module: CGFloat = 14     // module corner radius
    static let gap: CGFloat = 10
}

/// Critically damped by default: nothing here was flicked, so nothing bounces.
let calm = Animation.spring(response: 0.35, dampingFraction: 1)

struct PanelView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PanelLayout.key) private var hiddenRaw = ""
    @State var page: Page = .main
    @State var editing = false

    enum Page { case main, settings }

    private var layout: PanelLayout { PanelLayout(raw: hiddenRaw) }
    private var motion: Animation { reduceMotion ? .easeInOut(duration: 0.15) : calm }

    /// Shown normally, or always while editing (hidden ones dimmed with a +).
    private func shows(_ item: PanelItem) -> Bool { editing || !layout.isHidden(item) }

    private func toggle(_ item: PanelItem) {
        var l = layout
        l.toggle(item)
        withAnimation(motion) { hiddenRaw = l.raw }
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch page {
            case .main:
                mainPage
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            case .settings:
                SettingsView(model: model,
                             onBack: { withAnimation(motion) { page = .main } },
                             onEditPanel: { withAnimation(motion) { page = .main; editing = true } })
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(12)
        .frame(width: Metrics.width)
        .clipped()
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : calm, value: model.config)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : calm, value: model.battery?.percent)
        .onAppear { model.refresh() }
    }

    private var mainPage: some View {
        VStack(spacing: Metrics.gap) {
            hero
            if !model.installed {
                InstallModule(busy: model.busy, title: "Set up charge limiting",
                              detail: "Installs a small helper that writes your limit straight to the battery firmware. It keeps working while the Mac sleeps or this app is closed.",
                              button: "Install Helper") { model.installDaemon() }
            } else if model.daemon == nil {
                InstallModule(busy: model.busy, title: "Helper isn’t responding",
                              detail: model.daemonError ?? "The background helper didn’t answer.",
                              button: "Reinstall Helper") { model.installDaemon() }
            } else {
                if let l = model.macOSLimit, model.config.limitEnabled { macOSLimitWarning(l) }
                limitModule
                if shows(.powerFlow), let b = model.battery {
                    PowerFlowModule(battery: b)
                        .editable(.powerFlow, editing: editing, layout: layout) { toggle(.powerFlow) }
                }
                if shows(.quickActions) {
                    quickActions
                        .editable(.quickActions, editing: editing, layout: layout) { toggle(.quickActions) }
                }
            }
            if PanelItem.stats.contains(where: shows) { healthModule }
            if let msg = model.message { messageRow(msg) }
            footer
        }
    }

    // MARK: Hero

    private var hero: some View {
        let b = model.battery
        return HStack(spacing: 14) {
            BatteryGlyph(level: b?.percent ?? 0,
                         limit: model.daemon != nil && model.config.limitEnabled ? model.config.upperLimit : nil,
                         tint: tint)
                .frame(width: 58, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(b?.percent ?? 0)%")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .tracking(-0.6)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(headline)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                Text(powerLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private var tint: Color {
        guard let b = model.battery else { return .secondary }
        if model.daemon?.heatHold == true { return .orange }
        if b.percent <= 20 && !b.externalConnected { return .red }
        return b.externalConnected ? .green : Color.primary.opacity(0.55)
    }

    private var headline: String {
        if let s = model.daemon?.state, !s.isEmpty { return s }
        return model.installed ? "Helper not responding" : "Charge limit not set up"
    }

    private var powerLine: String {
        guard let b = model.battery else { return "No battery" }
        var parts = [b.externalConnected ? (b.isCharging ? "Charging" : "Power adapter") : "Battery"]
        if abs(b.powerW) >= 0.5 { parts.append(String(format: "%.1f W", abs(b.powerW))) }
        if let w = b.adapterWatts, b.externalConnected { parts.append("\(w) W charger") }
        if !b.externalConnected, let m = b.timeRemainingMinutes { parts.append("\(m / 60):\(String(format: "%02d", m % 60)) left") }
        return parts.joined(separator: " · ")
    }

    // MARK: Limit

    private var limitModule: some View {
        Module {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Charge Limit").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if model.config.limitEnabled {
                        Text("\(model.config.upperLimit)%")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    Toggle("", isOn: binding(\.limitEnabled))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                LimitSlider(value: Binding(get: { model.config.upperLimit },
                                           set: { v in model.update { $0.upperLimit = v } }),
                            current: model.battery?.percent ?? 0,
                            enabled: model.config.limitEnabled)
                    .frame(height: 30)
                HStack(spacing: 4) {
                    Text(!model.config.limitEnabled ? "macOS charges normally"
                         : model.config.holdsAtLimit ? "Holds at \(model.config.upperLimit)% on the charger"
                         : "Stops at \(model.config.upperLimit)%, resumes below \(model.config.lowerLimit)%")
                        .contentTransition(.numericText())
                    Spacer()
                    if model.config.limitEnabled {
                        Menu {
                            Picker("Resume charging", selection: binding(\.restartGap)) {
                                Text("Hold at limit").tag(1)
                                Text("3% below limit").tag(3)
                                Text("5% below limit").tag(5)
                                Text("10% below limit").tag(10)
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Text(model.config.holdsAtLimit ? "Hold" : "−\(model.config.restartGap)%")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                if let e = model.daemon?.lastError {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3)
                }
            }
        }
    }

    // MARK: Quick actions

    private var quickActions: some View {
        let b = model.battery
        let onAC = b?.externalConnected == true
        let on = model.config.limitEnabled
        return Module {
            HStack(alignment: .top, spacing: 0) {
                QuickToggle(symbol: "bolt.fill", title: "Top Up", subtitle: onAC ? "to 100% once" : "plug in first",
                            isOn: model.config.topUpToFull, tint: .green,
                            enabled: onAC && on) {
                    model.update { $0.topUpToFull.toggle(); if $0.topUpToFull { $0.dischargeToLimit = false } }
                }
                QuickToggle(symbol: "arrow.down.right", title: "Discharge", subtitle: onAC ? "to \(model.config.upperLimit)%" : "plug in first",
                            isOn: model.config.dischargeToLimit, tint: .blue,
                            enabled: onAC && on && (b?.percent ?? 0) > model.config.upperLimit && model.daemon?.adapterKey != nil) {
                    model.update { $0.dischargeToLimit.toggle(); if $0.dischargeToLimit { $0.topUpToFull = false } }
                }
                QuickToggle(symbol: "thermometer.medium", title: "Heat Guard",
                            subtitle: model.daemon?.heatHold == true ? "pausing now" : "above \(Int(model.config.heatLimitC))°C",
                            isOn: model.config.heatProtection, tint: .orange, enabled: true) {
                    model.update { $0.heatProtection.toggle() }
                }
            }
        }
    }

    // MARK: Health

    private func uptimeDetail(_ up: Uptime) -> String {
        if up.hours >= RestartReminder.thresholdHours { return "Restart recommended" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(up.bootDate) ? "'since' HH:mm" : "'since' EEE HH:mm"
        return f.string(from: up.bootDate)
    }

    private struct StatItem: Identifiable {
        let item: PanelItem
        let value: String
        let detail: String
        var id: PanelItem { item }
    }

    private func statItems(_ b: BatterySnapshot) -> [StatItem] {
        let macOS = model.macOSHealth
        var all = [
            StatItem(item: .health, value: macOS?.maximumCapacityPercent.map { "\($0)%" } ?? "—",
                     detail: macOS?.condition ?? "System Settings"),
            StatItem(item: .capacity, value: "\(b.rawMaxCapacity) mAh",
                     detail: String(format: "%.1f%% of %d", b.healthPercent, b.designCapacity)),
            StatItem(item: .cycles, value: "\(b.cycleCount)", detail: "of 1000 rated"),
            StatItem(item: .temperature, value: String(format: "%.1f°", b.temperatureC),
                     detail: b.temperatureC >= 35 ? "Warm" : "Normal"),
        ]
        if let up = model.uptime {
            all.append(StatItem(item: .uptime, value: up.shortText, detail: uptimeDetail(up)))
        }
        return all.filter { shows($0.item) }
    }

    private var healthModule: some View {
        Module {
            if let b = model.battery {
                let items = statItems(b)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
                    ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { i in
                        GridRow {
                            ForEach(items[i..<min(i + 2, items.count)]) { s in
                                Stat(label: s.item.title, value: s.value, detail: s.detail)
                                    .editable(s.item, editing: editing, layout: layout, badgeSize: 16, inset: true) { toggle(s.item) }
                            }
                            if i + 1 == items.count {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No battery found").foregroundStyle(.secondary)
            }
        }
    }

    private func macOSLimitWarning(_ limit: Int) -> some View {
        Module {
            VStack(alignment: .leading, spacing: 6) {
                Label("macOS’s own \(limit)% limit is also on", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("It waits for a bigger drop before charging again, so the battery can sit below your limit on the charger. Set it to 100% in Battery → Charging and let BatteryHealth hold the limit.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Battery Settings") { model.openBatterySettings() }
                    .controlSize(.small)
            }
        }
    }

    private func messageRow(_ msg: String) -> some View {
        Text(msg)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .transition(.opacity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if editing {
                Text("Hide with −, bring back with +")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                Spacer()
                Button("Done") { withAnimation(motion) { editing = false } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .transition(.opacity)
            } else {
                Spacer()
                Button { withAnimation(motion) { page = .settings } } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("Settings")
                .accessibilityLabel("Settings")
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
        .frame(minHeight: 24)
    }

    private func binding<T>(_ kp: WritableKeyPath<ChargeConfig, T>) -> Binding<T> {
        Binding(get: { model.config[keyPath: kp] }, set: { v in model.update { $0[keyPath: kp] = v } })
    }
}

// MARK: - Components

/// A Control Center module: a soft, slightly raised tile on the panel material.
struct Module<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.module, style: .continuous)
                    .fill(.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.module, style: .continuous)
                    .strokeBorder(.primary.opacity(0.05), lineWidth: 0.5)
            )
    }
}

private struct Stat: View {
    let label: String
    let value: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .tracking(-0.2)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Battery outline filled to the current level, with a notch at the limit.
private struct BatteryGlyph: View {
    let level: Int
    let limit: Int?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let nub: CGFloat = 4
            let body = CGSize(width: geo.size.width - nub - 1.5, height: geo.size.height)
            let inset: CGFloat = 3
            let inner = body.width - inset * 2
            HStack(spacing: 1.5) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.primary.opacity(0.35), lineWidth: 1.5)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: max(4, inner * CGFloat(min(level, 100)) / 100))
                        .padding(inset)
                    if let limit, limit < 100 {
                        Capsule()
                            .fill(level > limit ? AnyShapeStyle(.background) : AnyShapeStyle(.primary.opacity(0.55)))
                            .frame(width: 2, height: body.height - inset * 2 - 4)
                            .offset(x: inset + inner * CGFloat(limit) / 100 - 0.75)
                    }
                }
                .frame(width: body.width, height: body.height)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(.primary.opacity(0.35))
                    .frame(width: nub, height: body.height * 0.36)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Battery \(level) percent\(limit.map { ", limit \($0) percent" } ?? "")")
    }
}

/// Control Center–style fat slider: the fill tracks the pointer 1:1 from the
/// first touch, snaps to 5% steps with a light haptic tick, and shows the
/// current charge as a faint marker so the limit reads against reality.
private struct LimitSlider: View {
    @Binding var value: Int
    let current: Int
    let enabled: Bool

    private let range = ChargeConfig.limitRange
    private let step = 5
    @State private var dragValue: Double?

    private func fraction(_ v: Double) -> CGFloat {
        CGFloat((v - Double(range.lowerBound)) / Double(range.upperBound - range.lowerBound))
    }

    var body: some View {
        GeometryReader { geo in
            let shown = dragValue ?? Double(value)
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule()
                    .fill(enabled ? AnyShapeStyle(Color.green.gradient) : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    .frame(width: max(geo.size.height, w * fraction(shown)))
                if current >= range.lowerBound {
                    Capsule()
                        .fill(.primary.opacity(0.35))
                        .frame(width: 2, height: geo.size.height * 0.45)
                        .offset(x: min(w - 6, max(4, w * fraction(Double(current)) - 1)))
                        .accessibilityHidden(true)
                }
                Image(systemName: "battery.75percent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(enabled ? .white : .secondary)
                .shadow(color: .black.opacity(enabled ? 0.15 : 0), radius: 1, y: 0.5)
                .padding(.horizontal, 10)
                .allowsHitTesting(false)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }
                        let raw = Double(range.lowerBound) + Double(g.location.x / w) * Double(range.upperBound - range.lowerBound)
                        let clamped = min(Double(range.upperBound), max(Double(range.lowerBound), raw))
                        dragValue = clamped
                        let snapped = Int((clamped / Double(step)).rounded()) * step
                        if snapped != value {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            value = snapped
                        }
                    }
                    .onEnded { _ in
                        withAnimation(calm) { dragValue = nil }
                    }
            )
        }
        .opacity(enabled ? 1 : 0.6)
        .accessibilityElement()
        .accessibilityLabel("Charge limit")
        .accessibilityValue("\(value) percent")
        .accessibilityAdjustableAction { dir in
            guard enabled else { return }
            switch dir {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

/// Round Control Center toggle with a caption.
private struct QuickToggle: View {
    let symbol: String
    let title: String
    let subtitle: String
    let isOn: Bool
    let tint: Color
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(isOn ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(0.1)))
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isOn ? .white : .primary)
                }
                .frame(width: 38, height: 38)
                VStack(spacing: 0) {
                    Text(title).font(.system(size: 11, weight: .medium))
                    Text(subtitle).font(.system(size: 9.5)).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(subtitle)
    }
}

/// Feedback on press, not release.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 1), value: configuration.isPressed)
    }
}

private struct InstallModule: View {
    let busy: Bool
    let title: String
    let detail: String
    let button: String
    let action: () -> Void

    var body: some View {
        Module {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: action) {
                    Text(busy ? "Waiting…" : button).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy)
            }
        }
    }
}
