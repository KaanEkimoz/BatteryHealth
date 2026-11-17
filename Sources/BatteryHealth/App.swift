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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        MainActor.assumeIsolated {
                            // Draw through a real window so AppKit-backed controls
                            // (toggles, menus) render; ImageRenderer can't draw them.
                            for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
                                let host = NSHostingView(rootView: PanelView(model: model)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea()))
                                host.frame.size = host.fittingSize
                                let window = NSWindow(contentRect: host.frame, styleMask: .borderless,
                                                      backing: .buffered, defer: false)
                                window.appearance = NSAppearance(named: appearance)
                                window.backgroundColor = .windowBackgroundColor
                                window.contentView = host
                                host.layoutSubtreeIfNeeded()
                                host.display()
                                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                                host.cacheDisplay(in: host.bounds, to: rep)
                                let out = path.replacingOccurrences(of: ".png", with: "\(suffix).png")
                                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
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

    /// A plain leaf. macOS draws SF Symbols in the menu bar as templates, so it
    /// is white on a dark bar and follows highlight like the system icons.
    var body: some View {
        Image(systemName: "leaf.fill")
            .accessibilityLabel("BatteryHealth")
    }
}
