import AppKit

/// Renders terminal output as an image in the terminal's colors. Used by "copy output as image"
/// in the app and by the Telegram bot.
enum TerminalImageRenderer {
    struct Style {
        var fontSize: CGFloat
        var isDark: Bool
    }

    private static let horizontalPadding: CGFloat = 24
    private static let verticalPadding: CGFloat = 22

    /// Style of the app's terminal: font size and theme from Settings.
    @MainActor
    static func appStyle() -> Style {
        let defaults = UserDefaults.standard
        let fontSize = defaults.object(forKey: "terminalFontSize") as? Double ?? 13
        let isDark: Bool
        switch defaults.string(forKey: "appearance") {
        case "dark": isDark = true
        case "light": isDark = false
        default: isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return Style(fontSize: CGFloat(fontSize), isDark: isDark)
    }

    /// Output without the "$ command" line and the "[Процесс завершён …]" service lines.
    static func resultText(from output: String) -> String {
        var lines = output.components(separatedBy: .newlines)
        if lines.first?.hasPrefix("$ ") == true {
            lines.removeFirst()
            while lines.first?.isEmpty == true { lines.removeFirst() }
        }
        while let last = lines.last,
              last.isEmpty || last.hasPrefix("[Процесс завершён") || last == "[Остановка процесса…]" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// Image with a fixed text width, as used by the app's copy button.
    static func image(for text: String, style: Style, contentWidth: CGFloat = 1_152) -> NSImage {
        let attributed = attributedText(text, style: style)
        let textHeight = ceil(attributed.boundingRect(
            with: NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height)
        let size = imageSize(contentWidth: contentWidth, textHeight: textHeight)
        let image = NSImage(size: size)
        image.lockFocus()
        draw(attributed, in: size, contentWidth: contentWidth, textHeight: textHeight, style: style)
        image.unlockFocus()
        return image
    }

    /// PNG pages for Telegram: the width follows the longest line (so tables keep their layout),
    /// long output is split into pages of `linesPerPage` lines; at most `maxPages` last pages are kept.
    static func pngPages(
        for text: String,
        style: Style,
        linesPerPage: Int = 60,
        maxPages: Int = 10,
        scale: CGFloat = 2
    ) -> (pages: [Data], truncated: Bool) {
        let lines = text.isEmpty ? ["(вывода нет)"] : text.components(separatedBy: "\n")
        var chunks: [String] = stride(from: 0, to: lines.count, by: linesPerPage).map {
            lines[$0..<min($0 + linesPerPage, lines.count)].joined(separator: "\n")
        }
        let truncated = chunks.count > maxPages
        if truncated { chunks = Array(chunks.suffix(maxPages)) }

        // One width for all pages, from the longest line, between 480 and 1400 points.
        let natural = attributedText(text.isEmpty ? "(вывода нет)" : text, style: style).boundingRect(
            with: NSSize(width: CGFloat(100_000), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).width
        let contentWidth = min(max(ceil(natural) + 2, 480), 1_400)

        let pages = chunks.compactMap { chunk in
            pngData(for: chunk, style: style, contentWidth: contentWidth, scale: scale)
        }
        return (pages, truncated)
    }

    private static func pngData(for text: String, style: Style, contentWidth: CGFloat, scale: CGFloat) -> Data? {
        let attributed = attributedText(text, style: style)
        let textHeight = ceil(attributed.boundingRect(
            with: NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height)
        let size = imageSize(contentWidth: contentWidth, textHeight: textHeight)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // The bitmap is in pixels; draw in points scaled up so the whole canvas is used and text stays sharp.
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        transform.concat()
        draw(attributed, in: size, contentWidth: contentWidth, textHeight: textHeight, style: style)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func attributedText(_ text: String, style: Style) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = 2
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: style.fontSize, weight: .regular),
            .foregroundColor: foreground(style),
            .paragraphStyle: paragraphStyle
        ])
    }

    private static func imageSize(contentWidth: CGFloat, textHeight: CGFloat) -> NSSize {
        NSSize(width: contentWidth + horizontalPadding * 2, height: max(80, textHeight + verticalPadding * 2))
    }

    private static func draw(
        _ attributed: NSAttributedString,
        in size: NSSize,
        contentWidth: CGFloat,
        textHeight: CGFloat,
        style: Style
    ) {
        background(style).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        attributed.draw(
            with: NSRect(x: horizontalPadding, y: verticalPadding, width: contentWidth, height: textHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    private static func foreground(_ style: Style) -> NSColor {
        style.isDark ? NSColor(calibratedWhite: 0.92, alpha: 1) : NSColor(calibratedWhite: 0.12, alpha: 1)
    }

    private static func background(_ style: Style) -> NSColor {
        style.isDark ? NSColor(calibratedWhite: 0.075, alpha: 1) : NSColor(calibratedWhite: 0.97, alpha: 1)
    }
}
