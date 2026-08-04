import AppKit
import Foundation

struct ScriptItem: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor
final class ScriptLibrary: ObservableObject {
    @Published private(set) var scripts: [ScriptItem] = []
    @Published var selectedScriptID: String?
    @Published private(set) var runningScriptID: String?
    @Published private(set) var output = "Выберите скрипт и нажмите кнопку запуска.\n"
    @Published private(set) var terminationStatus: Int32?

    private var process: Process?
    private var outputPipe: Pipe?
    private var inputPipe: Pipe?
    private let defaults = UserDefaults.standard
    private let folderKey = "scriptsFolderPath"
    private let notesKey = "scriptNotes"
    private let orderKey = "scriptOrder"

    var folderURL: URL? {
        guard let path = defaults.string(forKey: folderKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    var folderPath: String { folderURL?.path ?? "Папка не выбрана" }

    init() {
        reload()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Выберите папку со скриптами"
        panel.prompt = "Выбрать"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let folderURL { panel.directoryURL = folderURL }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        defaults.set(url.path, forKey: folderKey)
        reload()
    }

    func reload() {
        guard let folderURL else {
            scripts = []
            selectedScriptID = nil
            return
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isHiddenKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        let discoveredScripts = urls.filter { url in
            let values = try? url.resourceValues(forKeys: keys)
            return values?.isRegularFile == true && url.pathExtension.lowercased() == "sh"
        }
        .map(ScriptItem.init)
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let savedOrder = defaults.stringArray(forKey: orderKey) ?? []
        let orderPositions = Dictionary(uniqueKeysWithValues: savedOrder.enumerated().map { ($1, $0) })
        scripts = discoveredScripts.sorted { left, right in
            switch (orderPositions[left.id], orderPositions[right.id]) {
            case let (leftIndex?, rightIndex?): leftIndex < rightIndex
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }
        saveCurrentOrder()

        if selectedScriptID == nil || !scripts.contains(where: { $0.id == selectedScriptID }) {
            selectedScriptID = scripts.first?.id
        }
    }

    func note(for script: ScriptItem) -> String {
        notes()[script.id] ?? ""
    }

    func setNote(_ note: String, for script: ScriptItem) {
        var allNotes = notes()
        if note.isEmpty { allNotes.removeValue(forKey: script.id) }
        else { allNotes[script.id] = note }
        defaults.set(allNotes, forKey: notesKey)
        objectWillChange.send()
    }

    func moveScript(withID sourceID: String, to targetID: String) {
        guard sourceID != targetID,
              let sourceIndex = scripts.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = scripts.firstIndex(where: { $0.id == targetID }) else { return }

        let movedScript = scripts.remove(at: sourceIndex)
        let destination = min(targetIndex, scripts.endIndex)
        scripts.insert(movedScript, at: destination)
        saveCurrentOrder()
    }

    func toggle(_ script: ScriptItem) {
        if runningScriptID == script.id { stopRunningScript() }
        else { run(script) }
    }

    func run(_ script: ScriptItem) {
        stopRunningScript()
        let launch = launchCommand(for: script.url)
        output = "$ \(([launch.executable.path] + launch.arguments).joined(separator: " "))\n\n"
        terminationStatus = nil

        let newProcess = Process()
        let pipe = Pipe()
        let newInputPipe = Pipe()
        newProcess.executableURL = launch.executable
        newProcess.arguments = launch.arguments
        newProcess.currentDirectoryURL = script.url.deletingLastPathComponent()
        newProcess.standardOutput = pipe
        newProcess.standardError = pipe
        newProcess.standardInput = newInputPipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in self?.output += text }
        }

        newProcess.terminationHandler = { [weak self, weak newProcess] _ in
            let status = newProcess?.terminationStatus ?? -1
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.output += "\n\n[Процесс завершён с кодом \(status)]\n"
                self.terminationStatus = status
                self.runningScriptID = nil
                self.process = nil
                self.outputPipe = nil
                self.inputPipe = nil
            }
        }

        do {
            try newProcess.run()
            process = newProcess
            outputPipe = pipe
            inputPipe = newInputPipe
            runningScriptID = script.id
            selectedScriptID = script.id
        } catch {
            output += "Ошибка запуска: \(error.localizedDescription)\n"
            terminationStatus = -1
        }
    }

    func stopRunningScript() {
        guard let process, process.isRunning else { return }
        output += "\n[Остановка процесса…]\n"
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
    }

    func clearOutput() {
        output = ""
        terminationStatus = nil
    }

    func sendInput(_ input: String) {
        guard process?.isRunning == true, let inputPipe else { return }
        let line = input + "\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
            output += "\(input)\n"
        } catch {
            output += "\n[Не удалось отправить ввод: \(error.localizedDescription)]\n"
        }
    }

    private func notes() -> [String: String] {
        defaults.dictionary(forKey: notesKey) as? [String: String] ?? [:]
    }

    private func saveCurrentOrder() {
        defaults.set(scripts.map(\.id), forKey: orderKey)
    }

    private func launchCommand(for scriptURL: URL) -> (executable: URL, arguments: [String]) {
        if let contents = try? String(contentsOf: scriptURL, encoding: .utf8),
           let firstLine = contents.split(separator: "\n", maxSplits: 1).first,
           firstLine.hasPrefix("#!") {
            let command = firstLine.dropFirst(2).trimmingCharacters(in: .whitespaces)
            let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
            if let interpreter = parts.first {
                return (URL(fileURLWithPath: interpreter), Array(parts.dropFirst()) + [scriptURL.path])
            }
        }
        return (URL(fileURLWithPath: "/bin/zsh"), [scriptURL.path])
    }
}
