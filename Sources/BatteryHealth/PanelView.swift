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
    @AppStorage(PanelLayout.hiddenKey) private var hiddenRaw = ""
    @AppStorage(PanelLayout.orderKey) private var orderRaw = ""
    @State var page: Page = .main
    @State private var dragging: PanelItem?
    /// Stat tiles are all the same size in a 2-column grid, so a tile's slot
    /// is computed from its index rather than measured mid-drag (a measured
    /// frame would include the drag offset itself).
    @State private var tileSize = CGSize(width: (Metrics.width - 24 - Metrics.gap) / 2, height: 74)
    @State private var dragStartSlot = 0
    @State private var dragTranslation: CGSize = .zero

    enum Page { case main, settings }

    private var layout: PanelLayout { PanelLayout(hiddenRaw: hiddenRaw, orderRaw: orderRaw) }
    private var motion: Animation { reduceMotion ? .easeInOut(duration: 0.15) : calm }

    private func shows(_ item: PanelItem) -> Bool { !layout.isHidden(item) }

    private func setHidden(_ item: PanelItem, _ hide: Bool) {
        var l = layout
        l.setHidden(item, hide)
        withAnimation(motion) { hiddenRaw = l.hiddenRaw }
    }

    private func move(_ item: PanelItem, to target: PanelItem) {
        var l = layout
        l.move(item, to: target)
        withAnimation(motion) { orderRaw = l.orderRaw }
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch page {
            case .main:
                mainPage
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            case .settings:
                SettingsView(model: model, onBack: { withAnimation(motion) { page = .main } })
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
                InstallModule(busy: model.busy, title: L("Set up charge limiting"),
                              detail: L("BatteryHealth adds a small background service that writes your limit to the battery firmware, so it keeps working while the Mac sleeps or this app is closed. You’ll be asked for your password once."),
                              button: L("Set Up…")) { model.installDaemon() }
            } else if model.daemon == nil {
                InstallModule(busy: model.busy, title: L("Charge control isn’t responding"),
                              detail: model.daemonError ?? L("The background service didn’t answer."),
                              button: L("Repair…")) { model.installDaemon() }
            } else {
                if let l = model.macOSLimit, model.config.limitEnabled { macOSLimitWarning(l) }
                limitModule
                if shows(.powerFlow), let b = model.battery {
                    PowerFlowModule(battery: b)
                        .hoverRemovable(.powerFlow) { setHidden(.powerFlow, true) }
                }
                if shows(.quickActions) {
                    quickActions
                        .hoverRemovable(.quickActions) { setHidden(.quickActions, true) }
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
                Text(pct(b?.percent ?? 0))
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

    /// Built here rather than taken from the daemon's English state text, so
    /// it follows the app's language.
    private var headline: String {
        guard let d = model.daemon else {
            return model.installed ? L("Charge control not responding") : L("Charge limit not set up")
        }
        guard let b = model.battery else { return L("No battery") }
        let c = d.config
        let limit = pct(c.upperLimit)
        if d.backend == .unsupported { return L("Not supported on this Mac") }
        if !c.limitEnabled || c.upperLimit >= 100 { return L("No limit – macOS charges normally") }
        if c.topUpToFull { return b.percent >= 100 ? L("Topped up to \(pct(100))") : L("Topping up to \(pct(100))") }
        if c.dischargeToLimit { return L("Discharging to \(limit)") }
        if d.heatHold { return L("Paused: battery is \(String(format: "%.0f°", b.temperatureC))") }
        if !b.externalConnected { return L("Limit \(limit) armed") }
        if b.isCharging { return L("Charging to \(limit)") }
        if b.percent > c.upperLimit { return L("Settling to \(limit)") }
        if b.percent >= (c.holdsAtLimit ? c.upperLimit - 1 : c.lowerLimit) { return L("Holding at \(limit)") }
        return L("Waiting to charge")
    }

    private var powerLine: String {
        guard let b = model.battery else { return L("No battery") }
        var parts = [b.externalConnected ? (b.isCharging ? L("Charging") : L("Power adapter")) : L("Battery")]
        if abs(b.powerW) >= 0.5 { parts.append(String(format: "%.1f W", abs(b.powerW))) }
        if let w = b.adapterWatts, b.externalConnected { parts.append(L("\(w) W charger")) }
        if !b.externalConnected, let m = b.timeRemainingMinutes { parts.append(L("\(shortDuration(minutes: m)) left")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Limit

    private var limitModule: some View {
        Module {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("Charge Limit")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if model.config.limitEnabled {
                        Text(pct(model.config.upperLimit))
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
                    Text(!model.config.limitEnabled ? L("macOS charges normally")
                         : model.config.holdsAtLimit ? L("Holds at \(pct(model.config.upperLimit)) on the charger")
                         : L("Stops at \(pct(model.config.upperLimit)), resumes below \(pct(model.config.lowerLimit))"))
                        .contentTransition(.numericText())
                    Spacer()
                    if model.config.limitEnabled {
                        Menu {
                            Picker(L("Resume charging"), selection: binding(\.restartGap)) {
                                Text(L("Hold at limit")).tag(1)
                                Text(L("\(pct(3)) below limit")).tag(3)
                                Text(L("\(pct(5)) below limit")).tag(5)
                                Text(L("\(pct(10)) below limit")).tag(10)
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Text(model.config.holdsAtLimit ? L("Hold") : "−" + pct(model.config.restartGap))
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
                QuickToggle(symbol: "bolt.fill", title: L("Top Up"), subtitle: onAC ? L("to \(pct(100)) once") : L("plug in first"),
                            isOn: model.config.topUpToFull, tint: .green,
                            enabled: onAC && on) {
                    model.update { $0.topUpToFull.toggle(); if $0.topUpToFull { $0.dischargeToLimit = false } }
                }
                QuickToggle(symbol: "arrow.down.right", title: L("Discharge"), subtitle: onAC ? L("to \(pct(model.config.upperLimit))") : L("plug in first"),
                            isOn: model.config.dischargeToLimit, tint: .blue,
                            enabled: onAC && on && (b?.percent ?? 0) > model.config.upperLimit && model.daemon?.adapterKey != nil) {
                    model.update { $0.dischargeToLimit.toggle(); if $0.dischargeToLimit { $0.topUpToFull = false } }
                }
                QuickToggle(symbol: "thermometer.medium", title: L("Heat Guard"),
                            subtitle: model.daemon?.heatHold == true ? L("pausing now") : L("above \(Int(model.config.heatLimitC))°C"),
                            isOn: model.config.heatProtection, tint: .orange, enabled: true) {
                    model.update { $0.heatProtection.toggle() }
                }
            }
        }
    }

    // MARK: Health

    private func uptimeDetail(_ up: Uptime) -> String {
        if up.hours >= RestartReminder.thresholdHours { return L("Restart recommended") }
        let f = DateFormatter()
        f.locale = appLocale
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(up.bootDate) ? "jmm" : "EEEjmm")
        return L("since \(f.string(from: up.bootDate))")
    }

    private static func duration(_ minutes: Int) -> String {
        shortDuration(minutes: minutes)
    }

    /// On battery: macOS's estimate. Charging: time to the limit (or 100%),
    /// from the charge still missing and the current flowing in.
    private func timeLeft(_ b: BatterySnapshot) -> (value: String, detail: String) {
        if !b.externalConnected {
            guard let m = b.timeRemainingMinutes else { return ("—", L("Calculating…")) }
            return (Self.duration(m), L("on battery"))
        }
        let target = model.config.limitEnabled && !model.config.topUpToFull ? model.config.upperLimit : 100
        if b.isCharging, b.amperageA > 0.05, b.percent < target {
            let missingmAh = Double(target - b.percent) / 100 * Double(max(b.nominalCapacity, b.rawMaxCapacity))
            let minutes = Int((missingmAh / (b.amperageA * 1000) * 60).rounded(.up))
            return (Self.duration(max(1, minutes)), L("to \(pct(target))"))
        }
        if b.isCharging { return ("—", L("Calculating…")) }
        return b.percent >= target - 1 ? (L("Held"), L("at \(pct(target)) on power")) : ("—", L("on power adapter"))
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
            StatItem(item: .health, value: macOS?.maximumCapacityPercent.map(pct) ?? "—",
                     detail: macOS?.condition.map { $0 == "Good" ? L("Good") : $0 } ?? L("System Settings")),
            StatItem(item: .capacity, value: "\(b.rawMaxCapacity) mAh",
                     detail: L("\(pct1(b.healthPercent)) of \(String(b.designCapacity))")),
            StatItem(item: .cycles, value: "\(b.cycleCount)", detail: L("of 1000 rated")),
            StatItem(item: .temperature, value: String(format: "%.1f°", b.temperatureC),
                     detail: b.temperatureC >= 35 ? L("Warm") : L("Normal")),
        ]
        if let up = model.uptime {
            all.append(StatItem(item: .uptime, value: up.shortText, detail: uptimeDetail(up)))
        }
        let t = timeLeft(b)
        all.append(StatItem(item: .timeLeft, value: t.value, detail: t.detail))
        let order = layout.statOrder
        return all.filter { shows($0.item) }
            .sorted { order.firstIndex(of: $0.item)! < order.firstIndex(of: $1.item)! }
    }

    /// Each stat is its own small tile, two per row, like Control Center modules.
    /// Tiles are placed by slot in one layer so a reorder slides them, across
    /// rows too, instead of popping.
    @ViewBuilder
    private var healthModule: some View {
        if let b = model.battery {
            let items = statItems(b)
            let rows = (items.count + 1) / 2
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, s in
                    statTile(s, index: index, items: items)
                        .frame(width: tileSize.width, height: tileSize.height)
                        .offset(x: slotOrigin(index).x, y: slotOrigin(index).y)
                }
            }
            .frame(width: Metrics.width - 24,
                   height: CGFloat(rows) * tileSize.height + CGFloat(max(0, rows - 1)) * Metrics.gap,
                   alignment: .topLeading)
            .coordinateSpace(name: "stats")
            .background(alignment: .topLeading) {
                // Measures one tile's natural height; width is half the panel.
                Module { Stat(label: "X", value: "0", detail: "x") }
                    .frame(width: (Metrics.width - 24 - Metrics.gap) / 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { tileSize = geo.size }
                            .onChange(of: geo.size) { tileSize = $0 }
                    })
            }
        } else {
            Module { Text(L("No battery found")).foregroundStyle(.secondary) }
        }
    }

    private func slotOrigin(_ index: Int) -> CGPoint {
        CGPoint(x: CGFloat(index % 2) * (tileSize.width + Metrics.gap),
                y: CGFloat(index / 2) * (tileSize.height + Metrics.gap))
    }

    private func slot(at p: CGPoint, count: Int) -> Int? {
        guard tileSize.width > 0, tileSize.height > 0, p.y >= 0 else { return nil }
        let col = p.x < tileSize.width + Metrics.gap / 2 ? 0 : 1
        let row = Int(p.y / (tileSize.height + Metrics.gap))
        let i = row * 2 + col
        return i < count ? i : nil
    }

    /// The dragged tile follows the pointer 1:1 from wherever it was grabbed;
    /// the tile under the pointer gives up its slot and the rest slide over.
    private func dragOffset(index: Int) -> CGSize {
        let start = slotOrigin(dragStartSlot), now = slotOrigin(index)
        return CGSize(width: start.x + dragTranslation.width - now.x,
                      height: start.y + dragTranslation.height - now.y)
    }

    private func statTile(_ s: StatItem, index: Int, items: [StatItem]) -> some View {
        let isDragged = dragging == s.item
        return Module {
            Stat(label: s.item.title, value: s.value, detail: s.detail)
        }
        .contentShape(RoundedRectangle(cornerRadius: Metrics.module, style: .continuous))
        .hoverRemovable(s.item, badgeSize: 16) { setHidden(s.item, true) }
        .scaleEffect(isDragged ? 1.04 : 1)
        .shadow(color: .black.opacity(isDragged ? 0.22 : 0), radius: isDragged ? 10 : 0, y: isDragged ? 4 : 0)
        .offset(isDragged ? dragOffset(index: index) : .zero)
        .zIndex(isDragged ? 1 : 0)
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("stats"))
                .onChanged { g in
                    if dragging == nil {
                        dragStartSlot = index
                        withAnimation(.spring(response: 0.2, dampingFraction: 1)) { dragging = s.item }
                    }
                    dragTranslation = g.translation
                    if let t = slot(at: g.location, count: items.count), t != index {
                        move(s.item, to: items[t].item)
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                }
                .onEnded { _ in
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.85)) {
                        dragging = nil
                        dragTranslation = .zero
                    }
                }
        )
        .accessibilityAction(named: L("Move Earlier")) { if index > 0 { move(s.item, to: items[index - 1].item) } }
        .accessibilityAction(named: L("Move Later")) { if index + 1 < items.count { move(s.item, to: items[index + 1].item) } }
    }

    private func macOSLimitWarning(_ limit: Int) -> some View {
        Module {
            VStack(alignment: .leading, spacing: 6) {
                Label(L("macOS’s own \(pct(limit)) limit is also on"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(L("It waits for a bigger drop before charging again, so the battery can sit below your limit on the charger. Set it to \(pct(100)) in Battery → Charging and let BatteryHealth hold the limit."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Open Battery Settings")) { model.openBatterySettings() }
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
            addMenu
            Spacer()
            Button { withAnimation(motion) { page = .settings } } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .help(L("Settings"))
            .accessibilityLabel(L("Settings"))
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .frame(minHeight: 24)
    }

    /// + lists what's been hidden; picking one brings it back.
    private var addMenu: some View {
        let hidden = PanelItem.allCases.filter(layout.isHidden)
        return Menu {
            if hidden.isEmpty {
                Text(L("Everything is on the panel"))
            } else {
                Section(L("Add to Panel")) {
                    ForEach(hidden, id: \.self) { item in
                        Button { setHidden(item, false) } label: {
                            Label(item.title, systemImage: item.symbol)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(hidden.isEmpty ? L("Everything is on the panel") : L("Add to Panel"))
        .accessibilityLabel(L("Add to Panel"))
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
            Text(label.uppercased(with: appLocale))
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
        .accessibilityLabel(limit.map { L("Battery \(pct(level)), limit \(pct($0))") } ?? L("Battery \(pct(level))"))
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
        .accessibilityLabel(L("Charge Limit"))
        .accessibilityValue(pct(value))
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
                    Text(busy ? L("Waiting…") : button).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy)
            }
        }
    }
}
