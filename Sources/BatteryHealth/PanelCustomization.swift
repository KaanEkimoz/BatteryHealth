import SwiftUI
import UniformTypeIdentifiers

/// Parts of the panel people can hide. The charge limit itself always stays.
enum PanelItem: String, CaseIterable {
    case powerFlow, quickActions
    case health, capacity, cycles, temperature, uptime

    static let modules: [PanelItem] = [.powerFlow, .quickActions]
    static let stats: [PanelItem] = [.health, .capacity, .cycles, .temperature, .uptime]

    var title: String {
        switch self {
        case .powerFlow: "Power Flow"
        case .quickActions: "Actions"
        case .health: "Health"
        case .capacity: "Capacity"
        case .cycles: "Cycles"
        case .temperature: "Temperature"
        case .uptime: "Uptime"
        }
    }

    var symbol: String {
        switch self {
        case .powerFlow: "bolt.horizontal"
        case .quickActions: "circle.grid.3x3"
        case .health: "heart"
        case .capacity: "battery.100percent"
        case .cycles: "arrow.triangle.2.circlepath"
        case .temperature: "thermometer.medium"
        case .uptime: "clock"
        }
    }
}

/// What's hidden and the order of the stats, kept in UserDefaults as
/// comma-separated lists so the panel and Settings share one source.
struct PanelLayout {
    static let hiddenKey = "hiddenPanelItems"
    static let orderKey = "statOrder"

    var hiddenRaw: String
    var orderRaw: String

    var hidden: Set<PanelItem> { Set(Self.parse(hiddenRaw)) }
    func isHidden(_ item: PanelItem) -> Bool { hidden.contains(item) }

    /// Saved order first, then any stat the saved order doesn't know yet.
    var statOrder: [PanelItem] {
        let saved = Self.parse(orderRaw).filter { PanelItem.stats.contains($0) }
        return saved + PanelItem.stats.filter { !saved.contains($0) }
    }

    mutating func setHidden(_ item: PanelItem, _ hide: Bool) {
        var h = hidden
        if hide { h.insert(item) } else { h.remove(item) }
        hiddenRaw = h.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// Moves `item` to where `target` is, shifting the rest along.
    mutating func move(_ item: PanelItem, to target: PanelItem) {
        var order = statOrder
        guard item != target, let from = order.firstIndex(of: item),
              let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(item, at: to)
        orderRaw = order.map(\.rawValue).joined(separator: ",")
    }

    private static func parse(_ raw: String) -> [PanelItem] {
        raw.split(separator: ",").compactMap { PanelItem(rawValue: String($0)) }
    }
}

/// A − button that appears while the pointer is over the item, like the close
/// button on a macOS notification. The item stays fully usable underneath.
struct HoverRemovable: ViewModifier {
    let item: PanelItem
    var alignment: Alignment = .topLeading
    var badgeSize: CGFloat = 18
    /// Pull the badge half outside the item's corner (for big modules).
    var outside = true
    let remove: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if hovering {
                    Button(action: remove) {
                        Image(systemName: "minus")
                            .font(.system(size: badgeSize * 0.5, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: badgeSize, height: badgeSize)
                            .background(Circle().fill(.regularMaterial))
                            .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                            .contentShape(Circle().inset(by: -4))
                    }
                    .buttonStyle(PressStyle())
                    .offset(x: outside ? (alignment == .topTrailing ? 1 : -1) * badgeSize * 0.35 : 0,
                            y: outside ? -badgeSize * 0.35 : 0)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                    .help("Hide \(item.title)")
                    .accessibilityLabel("Hide \(item.title)")
                }
            }
            .onHover { inside in
                withAnimation(reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.25, dampingFraction: 1)) {
                    hovering = inside
                }
            }
            // Keyboard / VoiceOver path to the same action.
            .accessibilityAction(named: "Hide \(item.title)", remove)
    }
}

extension View {
    func hoverRemovable(_ item: PanelItem, alignment: Alignment = .topLeading, badgeSize: CGFloat = 18,
                        outside: Bool = true, remove: @escaping () -> Void) -> some View {
        modifier(HoverRemovable(item: item, alignment: alignment, badgeSize: badgeSize,
                                outside: outside, remove: remove))
    }
}

/// Live reordering: as a dragged stat passes over another, they swap places.
struct StatDropDelegate: DropDelegate {
    let target: PanelItem
    @Binding var dragging: PanelItem?
    let move: (PanelItem, PanelItem) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        move(dragging, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
