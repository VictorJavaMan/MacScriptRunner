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

            Divider()
            ShellTextEditor(text: $content)
        }
        .navigationTitle(fileName + (hasChanges ? " — изменён" : ""))
        .onAppear { load() }
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

private struct ShellTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.applyHighlighting(to: textView)
        }
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
