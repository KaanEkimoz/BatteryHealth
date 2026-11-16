import SwiftUI
import BatteryKit

@main
struct BatteryHealthApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Debug aid: `BatteryHealth --snapshot out.png` renders the panel and exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    let model = AppModel()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        MainActor.assumeIsolated {
                            let r = ImageRenderer(content: PanelView(model: model).background(Color(nsColor: .windowBackgroundColor)))
                            r.scale = 2
                            if let img = r.nsImage, let tiff = img.tiffRepresentation,
                               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                                try? png.write(to: URL(fileURLWithPath: path))
                            }
                            // Menu bar glyph states, light and dark bars, at 4x.
                            let states: [MenuBarGlyph.State] = [.notSetUp, .off, .holding(0.8), .charging(0.8), .heat(0.8)]
                            let strip = VStack(spacing: 0) {
                                ForEach([Color(white: 0.93), Color(white: 0.16)], id: \.self) { bg in
                                    HStack(spacing: 18) {
                                        ForEach(states.indices, id: \.self) { i in
                                            LimitRing(limit: { switch states[i] { case .notSetUp: return 0; case .off: return 1; case .holding(let l), .charging(let l), .heat(let l): return l } }(),
                                                      center: (["leaf.fill", "leaf.fill", "leaf.fill", "bolt.fill", "thermometer.medium"] as [String])[i],
                                                      lineWidth: 1.8, trackOpacity: i == 0 ? 0.55 : 0.3)
                                                .frame(width: 17, height: 17)
                                                .foregroundStyle(bg == Color(white: 0.93) ? Color.black : Color.white)
                                        }
                                    }
                                    .padding(10).background(bg)
                                }
                            }
                            let g = ImageRenderer(content: strip)
                            g.scale = 4
                            if let img = g.nsImage, let tiff = img.tiffRepresentation,
                               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                                try? png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-glyphs.png")))
                            }
                            exit(0)
                        }
                    }
                }
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(nsImage: MenuBarGlyph.image(state))
    }

    private var state: MenuBarGlyph.State {
        guard let d = model.daemon else { return .notSetUp }
        guard d.config.limitEnabled, d.config.upperLimit < 100 else { return .off }
        let limit = Double(d.config.upperLimit) / 100
        if d.heatHold { return .heat(limit) }
        if model.battery?.isCharging == true { return .charging(limit) }
        return .holding(limit)
    }
}
