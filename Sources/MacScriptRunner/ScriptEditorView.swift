import AppKit
import SwiftUI

struct ScriptEditorView: View {
    @EnvironmentObject private var model: ScriptLibrary
    @State private var currentURL: URL
    @State private var fileName: String
    @State private var content = ""
    @State private var savedContent = ""
    @State private var statusMessage = ""

    init(scriptID: String) {
        let url = URL(fileURLWithPath: scriptID)
        _currentURL = State(initialValue: url)
        _fileName = State(initialValue: url.lastPathComponent)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                TextField("Имя скрипта", text: $fileName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit { save() }
                Text(currentURL.deletingLastPathComponent().path)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(statusMessage.hasPrefix("Ошибка") ? .red : .secondary)
                }
                Button("Сохранить") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!hasChanges)
            }
            .padding(12)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)

            Divider()
            ShellTextEditor(text: $content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text("Строк: \(lineCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle(fileName + (hasChanges ? " — изменён" : ""))
        .onAppear { load() }
    }

    private var lineCount: Int {
        // A trailing newline starts another (empty) editable line.
        content.reduce(1) { $1.isNewline ? $0 + 1 : $0 }
    }

    private var hasChanges: Bool {
        content != savedContent || fileName != currentURL.lastPathComponent
    }

    private func load() {
        do {
            content = try String(contentsOf: currentURL, encoding: .utf8)
            savedContent = content
            statusMessage = ""
        } catch {
            statusMessage = "Ошибка чтения: \(error.localizedDescription)"
        }
    }

    private func save() {
        let cleanName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              cleanName != ".",
              cleanName != "..",
              !cleanName.contains("/") else {
            statusMessage = "Ошибка: некорректное имя файла"
            return
        }
        guard model.runningScriptID != currentURL.path else {
            statusMessage = "Ошибка: сначала остановите скрипт"
            return
        }

        let newURL = currentURL.deletingLastPathComponent().appendingPathComponent(cleanName)
        do {
            if newURL != currentURL {
                guard !FileManager.default.fileExists(atPath: newURL.path) else {
                    statusMessage = "Ошибка: файл с таким именем уже существует"
                    return
                }
                let oldURL = currentURL
                try FileManager.default.moveItem(at: oldURL, to: newURL)
                currentURL = newURL
                model.scriptWasRenamed(from: oldURL, to: newURL)
            }
            try content.write(to: currentURL, atomically: true, encoding: .utf8)
            savedContent = content
            fileName = currentURL.lastPathComponent
            statusMessage = "Сохранено"
            model.reload()
        } catch {
            statusMessage = "Ошибка сохранения: \(error.localizedDescription)"
        }
    }
}

private final class LineNumberRuler: NSView {
    private weak var clientView: NSView?
    override var isFlipped: Bool { true }

    init(scrollView: NSScrollView) {
        super.init(frame: .zero)
        clientView = scrollView.documentView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: clientView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func refresh() { needsDisplay = true }

    override func draw(_ rect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        guard let editor = clientView as? NSTextView,
              let layout = editor.layoutManager,
              let container = editor.textContainer else { return }
        layout.ensureLayout(for: container)
        let source = editor.string as NSString
        let visibleGlyphs = layout.glyphRange(forBoundingRect: editor.visibleRect.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y), in: container)
        let visibleCharacters = layout.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        var index = source.lineRange(for: NSRange(location: min(visibleCharacters.location, source.length), length: 0)).location
        var number = (source.substring(to: index) as String).reduce(1) { $1.isNewline ? $0 + 1 : $0 }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        while index <= source.length {
            let y: CGFloat
            if index < source.length {
                let glyph = layout.glyphIndexForCharacter(at: index)
                y = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            } else if source.length == 0 || (editor.string.last?.isNewline == true) {
                y = layout.extraLineFragmentRect.minY
            } else { break }
            let point = convert(NSPoint(x: 0, y: y + editor.textContainerOrigin.y), from: editor)
            if point.y > bounds.maxY { break }
            let label = String(number) as NSString
            label.draw(at: NSPoint(x: bounds.width - label.size(withAttributes: attributes).width - 8, y: point.y + 1), withAttributes: attributes)
            if index == source.length { break }
            index = NSMaxRange(source.lineRange(for: NSRange(location: index, length: 0)))
            number += 1
        }
    }
}

private final class EditorSurface: NSView {
    let scrollView: NSScrollView
    let numbers: LineNumberRuler

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        numbers = LineNumberRuler(scrollView: scrollView)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        for view in [numbers, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            numbers.leadingAnchor.constraint(equalTo: leadingAnchor),
            numbers.topAnchor.constraint(equalTo: topAnchor),
            numbers.bottomAnchor.constraint(equalTo: bottomAnchor),
            numbers.widthAnchor.constraint(equalToConstant: 54),
            scrollView.leadingAnchor.constraint(equalTo: numbers.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        numbers.needsDisplay = true
    }
}

private struct ShellTextEditor: NSViewRepresentable {
    @Binding var text: String

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorSurface, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 800, height: proposal.height ?? 500)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> EditorSurface {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        scrollView.documentView = textView
        context.coordinator.applyHighlighting(to: textView)
        return EditorSurface(scrollView: scrollView)
    }

    func updateNSView(_ surface: EditorSurface, context: Context) {
        let scrollView = surface.scrollView
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.applyHighlighting(to: textView)
        }
        surface.numbers.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        private var isHighlighting = false

        init(text: Binding<String>) { _text = text }

        func textDidChange(_ notification: Notification) {
            guard !isHighlighting, let textView = notification.object as? NSTextView else { return }
            text = textView.string
            applyHighlighting(to: textView)
        }

        func applyHighlighting(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            isHighlighting = true
            defer { isHighlighting = false }

            let fullRange = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ], range: fullRange)

            highlight(#"(?m)^#!.*$"#, color: .systemPurple, in: storage)
            highlight(#"(?m)#.*$"#, color: .systemGreen, in: storage)
            highlight(#"\"(?:\\.|[^\"\\])*\"|'[^']*'"#, color: .systemOrange, in: storage)
            highlight(#"\b(if|then|else|elif|fi|for|while|until|do|done|case|esac|in|function|select|return|exit)\b"#, color: .systemPink, in: storage)
            highlight(#"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$[0-9@#?!*$-]"#, color: .systemTeal, in: storage)
            highlight(#"\b[0-9]+(?:\.[0-9]+)?\b"#, color: .systemBlue, in: storage)
            storage.endEditing()
        }

        private func highlight(_ pattern: String, color: NSColor, in storage: NSTextStorage) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(location: 0, length: storage.length)
            regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
                if let match { storage.addAttribute(.foregroundColor, value: color, range: match.range) }
            }
        }
    }
}
