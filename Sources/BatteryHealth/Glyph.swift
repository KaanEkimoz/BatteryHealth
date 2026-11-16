import SwiftUI
import AppKit

/// The BatteryHealth mark: a ring that closes only as far as the charge limit,
/// with the limit's gap left open at the top-left. It deliberately says
/// nothing about the current percentage – the system battery item already does.
struct LimitRing: View {
    var limit: Double            // 0...1, how far the ring closes
    var center: String?          // SF Symbol in the middle
    var lineWidth: CGFloat
    var trackOpacity: Double = 0.3

    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary.opacity(trackOpacity), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: limit)
                .stroke(.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let center {
                Image(systemName: center)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.bold)
                    .padding(lineWidth * 1.9)
            }
        }
        .padding(lineWidth / 2)
    }
}

enum MenuBarGlyph {
    enum State: Equatable { case notSetUp, off, holding(Double), charging(Double), heat(Double) }

    private static var cache: [State: NSImage] = [:]

    /// Template image, so macOS tints it for light/dark menu bars and highlight.
    @MainActor static func image(_ state: State) -> NSImage {
        if let hit = cache[state] { return hit }
        let ring: LimitRing
        switch state {
        case .notSetUp:        ring = LimitRing(limit: 0, center: "leaf.fill", lineWidth: 1.8, trackOpacity: 0.55)
        case .off:             ring = LimitRing(limit: 1, center: "leaf.fill", lineWidth: 1.8)
        case .holding(let l):  ring = LimitRing(limit: l, center: "leaf.fill", lineWidth: 1.8)
        case .charging(let l): ring = LimitRing(limit: l, center: "bolt.fill", lineWidth: 1.8)
        case .heat(let l):     ring = LimitRing(limit: l, center: "thermometer.medium", lineWidth: 1.8)
        }
        let r = ImageRenderer(content: ring.frame(width: 17, height: 17).foregroundStyle(.black))
        r.scale = 2
        let img = r.nsImage ?? NSImage()
        img.isTemplate = true
        img.accessibilityDescription = "BatteryHealth"
        cache[state] = img
        return img
    }
}

extension MenuBarGlyph.State: Hashable {}
