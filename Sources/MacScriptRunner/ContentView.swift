import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ScriptLibrary

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if model.scripts.isEmpty {
                    ContentUnavailableView {
                        Label("Нет скриптов", systemImage: "terminal")
                    } description: {
                        Text(model.folderURL == nil
                             ? "Выберите папку в настройках приложения."
                             : "В выбранной папке нет файлов .sh")
                    } actions: {
                        Button("Выбрать папку") { model.chooseFolder() }
                    }
                } else {
                    List {
                        ForEach(model.scripts) { script in
                            ScriptRow(script: script)
                        }
                    }
                    .listStyle(.sidebar)
                }

                Divider()
                HStack {
                    Text("\(model.scripts.count) скриптов")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { model.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Обновить список")
                    Button { model.chooseFolder() } label: {
                        Image(systemName: "folder")
                    }
                    .help("Выбрать папку")
                }
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 440)
        } detail: {
            TerminalOutputView()
        }
        .navigationTitle("Script Runner")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload()
        }
    }
}

private struct ScriptRow: View {
    @EnvironmentObject private var model: ScriptLibrary
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var isEditingNote = false
    @State private var isDropTarget = false
    @FocusState private var noteFieldIsFocused: Bool
    let script: ScriptItem

    private var note: Binding<String> {
        Binding(
            get: { model.note(for: script) },
            set: { model.setNote($0, for: script) }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 30)
                .contentShape(Rectangle())
                .draggable(script.id) {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                        Text(script.name)
                    }
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .help("Перетащить скрипт")
            Button {
                model.selectedScriptID = script.id
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(script.name)
                        .font(.headline)
                        .lineLimit(1)
                    if isEditingNote {
                        TextField("Примечание", text: note)
                            .textFieldStyle(.plain)
                            .foregroundStyle(.secondary)
                            .focused($noteFieldIsFocused)
                            .onSubmit { finishEditingNote() }
                    } else {
                        Text(model.note(for: script).isEmpty ? "Без примечания" : model.note(for: script))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    model.selectedScriptID = script.id
                    isEditingNote = true
                    noteFieldIsFocused = true
                }
            )
            Button { model.toggle(script) } label: {
                Image(systemName: model.runningScriptID == script.id ? "stop.fill" : "play.fill")
                    .frame(width: 24, height: 24)
                    .foregroundStyle(model.runningScriptID == script.id ? Color.red : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help(model.runningScriptID == script.id ? "Остановить" : "Запустить")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                    }
            } else if model.selectedScriptID == script.id {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectionColor)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    }
            }
        }
        .onChange(of: noteFieldIsFocused) { _, hasFocus in
            if !hasFocus { isEditingNote = false }
        }
        .onChange(of: model.selectedScriptID) { _, selectedID in
            if selectedID != script.id { finishEditingNote() }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
        .listRowBackground(Color.clear)
        .dropDestination(for: String.self) { draggedIDs, _ in
            guard let draggedID = draggedIDs.first else { return false }
            model.moveScript(withID: draggedID, to: script.id)
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
        .overlay {
            RightClickView {
                model.selectedScriptID = script.id
                openWindow(id: "script-editor", value: script.id)
            }
        }
    }

    private var selectionColor: Color {
        colorScheme == .dark
            ? Color.accentColor.opacity(0.11)
            : Color.accentColor.opacity(0.09)
    }

    private func finishEditingNote() {
        noteFieldIsFocused = false
        isEditingNote = false
    }
}

private struct RightClickView: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> RightClickNSView {
        let view = RightClickNSView()
        view.action = context.coordinator.action
        return view
    }

    func updateNSView(_ nsView: RightClickNSView, context: Context) {
        context.coordinator.action = action
        nsView.action = context.coordinator.action
    }

    final class Coordinator {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
    }
}

private final class RightClickNSView: NSView {
    var action: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        NSApp.currentEvent?.type == .rightMouseDown ? self : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        action?()
    }
}

private struct TerminalOutputView: View {
    @EnvironmentObject private var model: ScriptLibrary
    @AppStorage("terminalFontSize") private var terminalFontSize = 13.0
    @AppStorage("terminalLineWrapping") private var terminalLineWrapping = true
    @State private var terminalInput = ""
    @State private var didCopyOutput = false
    @FocusState private var inputIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(statusText, systemImage: statusIcon)
                    .foregroundStyle(statusColor)
                Spacer()
                if didCopyOutput {
                    Label("Скопировано", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Menu {
                    Button("Копировать весь вывод") {
                        copyToPasteboard(model.output)
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])

                    Button("Копировать только результат") {
                        copyToPasteboard(outputWithoutServiceLines)
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.output.isEmpty)
                .help("Копировать вывод. Выделенный фрагмент также можно скопировать сочетанием ⌘C")
                Button("Очистить") { model.clearOutput() }
            }
            .padding(12)
            Divider()
            TerminalOutputTextView(
                text: model.output,
                fontSize: terminalFontSize,
                wrapsLines: terminalLineWrapping,
                onMiddleClickCopy: showCopyConfirmation
            )
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .foregroundStyle(model.runningScriptID == nil ? Color.secondary.opacity(0.45) : Color.accentColor)
                TextField("Введите ответ для скрипта…", text: $terminalInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: terminalFontSize, design: .monospaced))
                    .focused($inputIsFocused)
                    .disabled(model.runningScriptID == nil)
                    .onSubmit { sendTerminalInput() }
                Button { sendTerminalInput() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(model.runningScriptID == nil || terminalInput.isEmpty)
                .help("Отправить ввод")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .onChange(of: model.runningScriptID) { _, scriptID in
            if scriptID != nil { inputIsFocused = true }
        }
    }

    private var statusText: String {
        if model.runningScriptID != nil { return "Выполняется" }
        if let code = model.terminationStatus { return code == 0 ? "Завершено" : "Ошибка (код \(code))" }
        return "Терминал"
    }
    private var statusIcon: String {
        if model.runningScriptID != nil { return "circle.fill" }
        if model.terminationStatus == 0 { return "checkmark.circle.fill" }
        if model.terminationStatus != nil { return "exclamationmark.triangle.fill" }
        return "terminal"
    }
    private var statusColor: Color {
        if model.runningScriptID != nil { return .orange }
        if model.terminationStatus == 0 { return .green }
        if model.terminationStatus != nil { return .red }
        return .secondary
    }

    private func sendTerminalInput() {
        guard !terminalInput.isEmpty else { return }
        model.sendInput(terminalInput)
        terminalInput = ""
        inputIsFocused = true
    }

    private var outputWithoutServiceLines: String {
        var lines = model.output.components(separatedBy: .newlines)
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

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showCopyConfirmation()
    }

    private func showCopyConfirmation() {
        withAnimation { didCopyOutput = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { didCopyOutput = false }
        }
    }
}

private struct TerminalOutputTextView: NSViewRepresentable {
    let text: String
    let fontSize: Double
    let wrapsLines: Bool
    let onMiddleClickCopy: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMiddleClickCopy: onMiddleClickCopy)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = MiddleClickTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.middleClickAction = context.coordinator.didCopyLine
        textView.string = text
        scrollView.documentView = textView
        configureWrapping(textView: textView, scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MiddleClickTextView else { return }
        context.coordinator.onMiddleClickCopy = onMiddleClickCopy
        textView.middleClickAction = context.coordinator.didCopyLine
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        configureWrapping(textView: textView, scrollView: scrollView)

        guard textView.string != text else { return }
        let selectedRange = textView.selectedRange()
        let visibleBottom = scrollView.contentView.bounds.maxY
        let documentHeight = textView.bounds.height
        let shouldFollowOutput = documentHeight - visibleBottom < 40

        textView.string = text
        textView.setSelectedRange(NSRange(
            location: min(selectedRange.location, textView.string.utf16.count),
            length: 0
        ))
        if shouldFollowOutput || selectedRange.length == 0 {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func configureWrapping(textView: NSTextView, scrollView: NSScrollView) {
        scrollView.hasHorizontalScroller = !wrapsLines
        textView.isHorizontallyResizable = !wrapsLines
        textView.autoresizingMask = wrapsLines ? [.width] : []
        textView.textContainer?.widthTracksTextView = wrapsLines
        textView.textContainer?.containerSize = NSSize(
            width: wrapsLines ? max(scrollView.contentSize.width, 1) : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        if wrapsLines {
            textView.frame.size.width = max(scrollView.contentSize.width, 1)
        }
    }

    @MainActor
    final class Coordinator {
        var onMiddleClickCopy: () -> Void

        init(onMiddleClickCopy: @escaping () -> Void) {
            self.onMiddleClickCopy = onMiddleClickCopy
        }

        func didCopyLine() {
            onMiddleClickCopy()
        }
    }
}

private final class MiddleClickTextView: NSTextView {
    var middleClickAction: (() -> Void)?

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let source = string as NSString
        guard source.length > 0, index <= source.length else { return }

        let safeIndex = min(index, source.length - 1)
        let lineRange = source.lineRange(for: NSRange(location: safeIndex, length: 0))
        let line = source.substring(with: lineRange)
        let cleaned = line.replacingOccurrences(
            of: #"[ \t\r\n]+$"#,
            with: "",
            options: .regularExpression
        )

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(cleaned, forType: .string)
        middleClickAction?()
    }
}
