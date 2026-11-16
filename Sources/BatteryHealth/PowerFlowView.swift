import SwiftUI
import BatteryKit

/// Charger → Mac → Battery, with live watts. At the limit the battery branch
/// goes quiet: power bypasses the battery, which is the whole point.
struct PowerFlowModule: View {
    let battery: BatterySnapshot

    private var adapterW: Double { battery.externalConnected ? max(0, battery.adapterInW) : 0 }
    private var batteryW: Double { battery.batteryW }       // + charging, − discharging
    private var systemW: Double { max(0, battery.systemLoadW) }

    private enum Dir { case none, forward, backward }

    private var chargerDir: Dir { adapterW >= 0.5 ? .forward : .none }
    private var batteryDir: Dir { batteryW >= 0.5 ? .forward : batteryW <= -0.5 ? .backward : .none }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Power Flow").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 0) {
                Node(symbol: "powerplug.fill",
                     title: battery.externalConnected ? battery.adapterWatts.map { "of \($0) W charger" } ?? "Charger" : "Charger",
                     value: battery.externalConnected ? watts(adapterW) : "—",
                     active: chargerDir != .none, tint: .green)
                FlowLine(direction: chargerDir == .forward ? 1 : 0, tint: .green)
                Node(symbol: "laptopcomputer", title: "Mac", value: watts(systemW), active: true, tint: .primary)
                FlowLine(direction: batteryDir == .forward ? 1 : batteryDir == .backward ? -1 : 0,
                         tint: batteryDir == .backward ? .orange : .green)
                Node(symbol: batterySymbol, title: "Battery",
                     value: batteryDir == .none ? "idle" : (batteryW > 0 ? "+" : "−") + watts(abs(batteryW)),
                     active: batteryDir != .none, tint: batteryDir == .backward ? .orange : .green)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.05), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    private var batterySymbol: String {
        batteryDir == .forward ? "battery.100percent.bolt" : "battery.75percent"
    }

    private var summary: String {
        switch (battery.externalConnected, batteryDir) {
        case (true, .none): return "Battery bypassed"
        case (true, .forward): return "Charging"
        case (true, .backward): return adapterW < 0.5 ? "Settling to limit on battery" : "Charger + battery"
        case (false, _): return "On battery"
        }
    }

    private func watts(_ w: Double) -> String {
        w >= 10 ? String(format: "%.0f W", w) : String(format: "%.1f W", w)
    }
}

private struct Node: View {
    let symbol: String
    let title: String
    let value: String
    let active: Bool
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(active ? AnyShapeStyle(tint.opacity(0.18)) : AnyShapeStyle(Color.primary.opacity(0.07)))
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(active ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
            }
            .frame(width: 34, height: 34)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(title).font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .frame(width: 72)
    }
}

/// A track with dots travelling in the direction of flow. Static when idle or
/// when Reduce Motion is on (then a chevron shows the direction instead).
private struct FlowLine: View {
    let direction: Int   // 1 = left→right, -1 = right→left, 0 = none
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Capsule()
                    .fill(direction == 0 ? AnyShapeStyle(Color.primary.opacity(0.1)) : AnyShapeStyle(tint.opacity(0.3)))
                    .frame(height: 3)
                if direction != 0 {
                    if reduceMotion {
                        Image(systemName: direction > 0 ? "chevron.right" : "chevron.left")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(tint)
                    } else {
                        TimelineView(.animation) { tl in
                            let t = tl.date.timeIntervalSinceReferenceDate
                            Canvas { ctx, size in
                                let spacing: CGFloat = 14
                                let phase = CGFloat(t.truncatingRemainder(dividingBy: 1)) * spacing
                                var x = (direction > 0 ? phase : spacing - phase) - spacing
                                while x < size.width + spacing {
                                    if x >= 0 && x <= size.width {
                                        let edge = min(x, size.width - x) / 8
                                        ctx.opacity = Double(min(1, edge))
                                        ctx.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: size.height / 2 - 2.5, width: 5, height: 5)),
                                                 with: .color(tint))
                                    }
                                    x += spacing
                                }
                            }
                        }
                        .frame(width: w, height: 8)
                    }
                }
            }
            .frame(width: w, height: geo.size.height)
        }
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}
