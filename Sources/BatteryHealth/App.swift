import SwiftUI
import BatteryKit

@main
struct BatteryHealthApp: App {
    @StateObject private var model = AppModel()

    init() {
        _ = Updater.shared  // starts Sparkle's scheduled checks
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
                            // `--snapshot-page settings` renders that state instead.
                            let pageArg = args.firstIndex(of: "--snapshot-page").map { args[$0 + 1] } ?? "main"
                            // `--simulate-drag x1 y1 x2 y2` (points from the top-left) drags
                            // in a live window, renders mid-drag, then releases and exits.
                            if let d = args.firstIndex(of: "--simulate-drag") {
                                let n = (1...4).map { CGFloat(Double(args[d + $0]) ?? 0) }
                                Self.simulateDrag(model: model, from: CGPoint(x: n[0], y: n[1]),
                                             to: CGPoint(x: n[2], y: n[3]), path: path)
                                return
                            }
                            for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
                                let host = NSHostingView(rootView: PanelView(model: model,
                                                                             page: pageArg == "settings" ? .settings : .main)
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

    @MainActor private static func simulateDrag(model: AppModel, from: CGPoint, to: CGPoint, path: String) {
        let host = NSHostingView(rootView: PanelView(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea()))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        let h = host.bounds.height
        func event(_ type: NSEvent.EventType, _ p: CGPoint) {
            if let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: p.x, y: h - p.y), modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(e)
            }
        }
        func snap(_ suffix: String) {
            host.display()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "\(suffix).png")))
        }
        event(.leftMouseDown, from)
        let steps = 12
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(i)) {
                let t = CGFloat(i) / CGFloat(steps)
                event(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(steps) + 0.6) {
            snap("-mid")
            event(.leftMouseUp, to)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                snap("-after")
                print("statOrder:", UserDefaults.standard.string(forKey: PanelLayout.orderKey) ?? "(default)")
                exit(0)
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
