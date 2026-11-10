import AppKit
import SwiftUI
import UsageCore

/// Renders the dropdown and menu bar label to PNG files, in light and dark mode.
@MainActor
enum Snapshot {
    static func run(outputDir: String, useSampleData: Bool) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let store = UsageStore(startServices: false)
        store.loadNow()
        if useSampleData { applySample(to: store) }

        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)!

            let host = NSHostingView(rootView: UsagePanel(store: store).background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = appearance
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            save(view: host, to: dir.appendingPathComponent("panel-\(name).png"))
            window.orderOut(nil)

            let label = MenuBarLabel.image(for: MenuBarLabel.segments(for: store))
            save(label: label, appearance: appearance, to: dir.appendingPathComponent("menubar-\(name).png"))
        }
        print("Saved snapshots to \(dir.path)")
    }

    private static func applySample(to store: UsageStore) {
        let now = Date()
        store.claude = UsageSnapshot(provider: .claude, windows: [
            LimitWindow(key: "five_hour", label: "5-hour", usedPercent: 93, resetsAt: now.addingTimeInterval(5_400), windowMinutes: 300),
            LimitWindow(key: "seven_day", label: "Weekly", usedPercent: 41, resetsAt: now.addingTimeInterval(300_000), windowMinutes: 10080),
        ], observedAt: now.addingTimeInterval(-120), source: "sample", plan: nil)
        store.codex = UsageSnapshot(provider: .codex, windows: [
            LimitWindow(key: "primary", label: "5-hour", usedPercent: 75, resetsAt: now.addingTimeInterval(2_000), windowMinutes: 300),
            LimitWindow(key: "secondary", label: "Weekly", usedPercent: 12, resetsAt: now.addingTimeInterval(400_000), windowMinutes: 10080),
        ], observedAt: now.addingTimeInterval(-30), source: "sample", plan: "plus")
    }

    private static func save(view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Draws the label on a menu-bar-like background, tinting it the way macOS tints template images.
    private static func save(label: NSImage, appearance: NSAppearance, to url: URL) {
        let isDark = appearance.name == .darkAqua
        let size = NSSize(width: label.size.width + 24, height: 24)
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            (isDark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            let rect = NSRect(x: 12, y: (size.height - label.size.height) / 2, width: label.size.width, height: label.size.height)
            if label.isTemplate {
                // Template: use the image as a mask filled with the menu bar text color.
                let tinted = NSImage(size: label.size, flipped: false) { r in
                    label.draw(in: r)
                    (isDark ? NSColor.white : NSColor.black).set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: rect)
            } else {
                label.draw(in: rect)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
