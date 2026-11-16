// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import SwiftUI
import AppKit

struct Icon: View {
    var body: some View {
        // macOS icon grid: 824pt squircle centred on a 1024 canvas, soft drop shadow.
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.85, blue: 0.47),
                                              Color(red: 0.09, green: 0.60, blue: 0.42)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)

            // Same mark as the menu bar: a ring that closes only to the limit.
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.28), lineWidth: 62)
                Circle()
                    .trim(from: 0, to: 0.8)
                    .stroke(.white, style: StrokeStyle(lineWidth: 62, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "leaf.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: 210, height: 210)
            }
            .frame(width: 470, height: 470)
            .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func png(_ size: Int) -> Data {
    let r = ImageRenderer(content: Icon())
    r.scale = CGFloat(size) / 1024
    let rep = NSBitmapImageRep(cgImage: r.cgImage!)
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
MainActor.assumeIsolated {
    for base in [16, 32, 128, 256, 512] {
        try! png(base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
        try! png(base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", dir.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
