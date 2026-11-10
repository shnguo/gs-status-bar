import AppKit
import UsageCore

/// Draws the menu bar text, e.g. "✳︎ 64%  ◎ 88%".
///
/// It's drawn as an image because the menu bar ignores text colors set in SwiftUI.
/// When nothing is low, the image is a template so macOS tints it like other menu bar items.
enum MenuBarLabel {
    struct Segment {
        let text: String
        let color: NSColor?
    }

    @MainActor
    static func segments(for store: UsageStore) -> [Segment] {
        let now = store.now
        let segments = store.visibleProviders.map { provider -> Segment in
            guard let window = store.snapshot(for: provider)?.headlineWindow(at: now) else {
                return Segment(text: "\(provider.glyph) –", color: nil)
            }
            let remaining = window.remainingPercent(at: now)
            return Segment(text: "\(provider.glyph) \(Fmt.percent(remaining))", color: Level(remaining: remaining).nsColor)
        }
        return segments.isEmpty ? [Segment(text: "GS", color: nil)] : segments
    }

    static func image(for segments: [Segment]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        let hasColor = segments.contains { $0.color != nil }
        // Template images only use the alpha channel, so black is fine; non-template ones need a real color.
        let baseColor: NSColor = hasColor ? .labelColor : .black

        let text = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            }
            text.append(NSAttributedString(string: segment.text, attributes: [
                .font: font,
                .foregroundColor: segment.color ?? baseColor,
            ]))
        }

        let size = text.size()
        let image = NSImage(size: NSSize(width: ceil(size.width), height: 18), flipped: false) { rect in
            text.draw(at: NSPoint(x: 0, y: (rect.height - size.height) / 2))
            return true
        }
        image.isTemplate = !hasColor
        return image
    }
}
