import SwiftUI

/// Parts of the panel people can hide. The charge limit itself always stays.
enum PanelItem: String, CaseIterable {
    case powerFlow, quickActions
    case health, capacity, cycles, temperature, uptime

    static let stats: [PanelItem] = [.health, .capacity, .cycles, .temperature, .uptime]

    var title: String {
        switch self {
        case .powerFlow: "Power Flow"
        case .quickActions: "Quick Actions"
        case .health: "Health"
        case .capacity: "Capacity"
        case .cycles: "Cycles"
        case .temperature: "Temperature"
        case .uptime: "Uptime"
        }
    }
}

/// Hidden items, kept in UserDefaults as a comma-separated list.
struct PanelLayout {
    static let key = "hiddenPanelItems"

    var raw: String
    var hidden: Set<PanelItem> {
        Set(raw.split(separator: ",").compactMap { PanelItem(rawValue: String($0)) })
    }
    func isHidden(_ item: PanelItem) -> Bool { hidden.contains(item) }

    mutating func toggle(_ item: PanelItem) {
        var h = hidden
        if h.contains(item) { h.remove(item) } else { h.insert(item) }
        raw = h.map(\.rawValue).sorted().joined(separator: ",")
    }
}

/// In edit mode: a − badge on shown items, a + badge on hidden ones (which
/// are drawn dimmed). The content underneath stops taking clicks meanwhile.
struct EditableItem: ViewModifier {
    let item: PanelItem
    let editing: Bool
    let hidden: Bool
    var badgeSize: CGFloat = 20
    /// Small items (stats) make room for the badge instead of being covered by it.
    var inset = false
    let toggle: () -> Void

    func body(content: Content) -> some View {
        content
            .padding(.leading, editing && inset ? badgeSize + 4 : 0)
            .allowsHitTesting(!editing)
            .opacity(editing && hidden ? 0.4 : 1)
            .overlay(alignment: .topLeading) {
                if editing {
                    Button(action: toggle) {
                        Image(systemName: hidden ? "plus" : "minus")
                            .font(.system(size: badgeSize * 0.5, weight: .bold))
                            .foregroundStyle(hidden ? Color.white : Color.primary)
                            .frame(width: badgeSize, height: badgeSize)
                            .background(
                                Circle().fill(hidden ? AnyShapeStyle(Color.green.gradient)
                                                     : AnyShapeStyle(.regularMaterial))
                            )
                            .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                            .contentShape(Circle().inset(by: -6))
                    }
                    .buttonStyle(PressStyle())
                    .offset(x: inset ? 0 : -badgeSize * 0.35, y: inset ? 0 : -badgeSize * 0.35)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                    .accessibilityLabel(hidden ? "Show \(item.title)" : "Hide \(item.title)")
                }
            }
    }
}

extension View {
    func editable(_ item: PanelItem, editing: Bool, layout: PanelLayout, badgeSize: CGFloat = 20,
                  inset: Bool = false, toggle: @escaping () -> Void) -> some View {
        modifier(EditableItem(item: item, editing: editing, hidden: layout.isHidden(item),
                              badgeSize: badgeSize, inset: inset, toggle: toggle))
    }
}
