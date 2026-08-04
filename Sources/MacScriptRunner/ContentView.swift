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
                        .onMove(perform: model.moveScripts)
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
    @State private var isEditingNote = false
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
            if model.selectedScriptID == script.id {
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

private struct TerminalOutputView: View {
    @EnvironmentObject private var model: ScriptLibrary
    @AppStorage("terminalFontSize") private var terminalFontSize = 13.0
    @AppStorage("terminalLineWrapping") private var terminalLineWrapping = true
    @State private var terminalInput = ""
    @FocusState private var inputIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(statusText, systemImage: statusIcon)
                    .foregroundStyle(statusColor)
                Spacer()
                Button("Очистить") { model.clearOutput() }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(terminalLineWrapping ? .vertical : [.vertical, .horizontal]) {
                    Text(model.output)
                        .font(.system(size: terminalFontSize, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .fixedSize(horizontal: !terminalLineWrapping, vertical: true)
                        .padding(14)
                        .id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: model.output) { _, _ in
                    withAnimation(.linear(duration: 0.08)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
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
}
