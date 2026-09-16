import AppKit
import Foundation

struct ScriptItem: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

struct ScriptGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var scriptIDs: [String]
}

private struct PersistedTerminalState: Codable {
    var outputs: [String: String]
    var terminationStatuses: [String: Int32]
    var lastRunDates: [String: Date]?
}

@MainActor
final class ScriptLibrary: ObservableObject {
    static let emptyOutputMessage = "Выберите скрипт и нажмите кнопку запуска."

    @Published private(set) var scripts: [ScriptItem] = []
    @Published private(set) var groups: [ScriptGroup] = []
    @Published var selectedScriptID: String? {
        didSet { updateDisplayedOutput() }
    }
    @Published private(set) var runningScriptID: String?
    @Published private(set) var output = ScriptLibrary.emptyOutputMessage
    @Published private(set) var terminationStatus: Int32?

    private var process: Process?
    private var outputPipe: Pipe?
    private var inputPipe: Pipe?
    private var outputsByScriptID: [String: String] = [:]
    private var terminationStatusesByScriptID: [String: Int32] = [:]
    private var lastRunDatesByScriptID: [String: Date] = [:]
    private var persistenceTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let folderKey = "scriptsFolderPath"
    private let notesKey = "scriptNotes"
    private let orderKey = "scriptOrder"
    private let groupsKey = "scriptGroups"

    var folderURL: URL? {
        guard let path = defaults.string(forKey: folderKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    var folderPath: String { folderURL?.path ?? "Папка не выбрана" }
    var isSelectedScriptRunning: Bool {
        selectedScriptID != nil && selectedScriptID == runningScriptID
    }

    init() {
        loadGroups()
        loadPersistedOutputs()
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

    func lastRunDate(for script: ScriptItem) -> Date? {
        lastRunDatesByScriptID[script.id]
    }

    var ungroupedScripts: [ScriptItem] {
        let groupedIDs = Set(groups.flatMap(\.scriptIDs))
        return scripts.filter { !groupedIDs.contains($0.id) }
    }

    func scripts(in group: ScriptGroup) -> [ScriptItem] {
        let positions = Dictionary(uniqueKeysWithValues: group.scriptIDs.enumerated().map { ($1, $0) })
        return scripts
            .filter { positions[$0.id] != nil }
            .sorted { (positions[$0.id] ?? 0) < (positions[$1.id] ?? 0) }
    }

    func groupID(for script: ScriptItem) -> UUID? {
        groups.first(where: { $0.scriptIDs.contains(script.id) })?.id
    }

    func createGroup(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        groups.append(ScriptGroup(id: UUID(), name: name, scriptIDs: []))
        saveGroups()
    }

    func renameGroup(_ groupID: UUID, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].name = name
        saveGroups()
    }

    func deleteGroup(_ groupID: UUID) {
        groups.removeAll { $0.id == groupID }
        saveGroups()
    }

    func assign(_ script: ScriptItem, to groupID: UUID?) {
        for index in groups.indices {
            groups[index].scriptIDs.removeAll { $0 == script.id }
        }
        if let groupID, let index = groups.firstIndex(where: { $0.id == groupID }) {
            groups[index].scriptIDs.append(script.id)
        }
        saveGroups()
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

    func scriptWasRenamed(from oldURL: URL, to newURL: URL) {
        let oldID = oldURL.path
        let newID = newURL.path

        var allNotes = notes()
        if let note = allNotes.removeValue(forKey: oldID) {
            allNotes[newID] = note
            defaults.set(allNotes, forKey: notesKey)
        }

        var savedOrder = defaults.stringArray(forKey: orderKey) ?? []
        if let index = savedOrder.firstIndex(of: oldID) {
            savedOrder[index] = newID
            defaults.set(savedOrder, forKey: orderKey)
        }


        var didChangeGroups = false
        for index in groups.indices {
            if let scriptIndex = groups[index].scriptIDs.firstIndex(of: oldID) {
                groups[index].scriptIDs[scriptIndex] = newID
                didChangeGroups = true
            }
        }
        if didChangeGroups { saveGroups() }

        if let storedOutput = outputsByScriptID.removeValue(forKey: oldID) {
            outputsByScriptID[newID] = storedOutput
        }
        if let storedStatus = terminationStatusesByScriptID.removeValue(forKey: oldID) {
            terminationStatusesByScriptID[newID] = storedStatus
        }
        if let lastRunDate = lastRunDatesByScriptID.removeValue(forKey: oldID) {
            lastRunDatesByScriptID[newID] = lastRunDate
        }
        if selectedScriptID == oldID { selectedScriptID = newID }
        savePersistedOutputs()
        reload()
    }

    func toggle(_ script: ScriptItem) {
        if runningScriptID == script.id { stopRunningScript() }
        else { run(script) }
    }

    func run(_ script: ScriptItem) {
        stopRunningScript()
        let launch = launchCommand(for: script.url)
        selectedScriptID = script.id
        lastRunDatesByScriptID[script.id] = Date()
        setOutput(
            "$ \(([launch.executable.path] + launch.arguments).joined(separator: " "))\n\n",
            for: script.id
        )
        terminationStatusesByScriptID.removeValue(forKey: script.id)
        updateDisplayedOutput()
        scheduleOutputPersistence()

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
            Task { @MainActor [weak self] in self?.appendOutput(text, for: script.id) }
        }

        newProcess.terminationHandler = { [weak self, weak newProcess] _ in
            let status = newProcess?.terminationStatus ?? -1
            Task { @MainActor [weak self] in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.appendOutput("\n\n[Процесс завершён с кодом \(status)]\n", for: script.id)
                self.terminationStatusesByScriptID[script.id] = status
                if self.selectedScriptID == script.id { self.terminationStatus = status }
                self.scheduleOutputPersistence()
                if self.process === newProcess {
                    self.runningScriptID = nil
                    self.process = nil
                    self.outputPipe = nil
                    self.inputPipe = nil
                }
            }
        }

        do {
            try newProcess.run()
            process = newProcess
            outputPipe = pipe
            inputPipe = newInputPipe
            runningScriptID = script.id
        } catch {
            appendOutput("Ошибка запуска: \(error.localizedDescription)\n", for: script.id)
            terminationStatusesByScriptID[script.id] = -1
            updateDisplayedOutput()
            scheduleOutputPersistence()
        }
    }

    func stopRunningScript() {
        guard let process, process.isRunning, let runningScriptID else { return }
        appendOutput("\n[Остановка процесса…]\n", for: runningScriptID)
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
    }

    func clearOutput() {
        if let selectedScriptID {
            outputsByScriptID.removeValue(forKey: selectedScriptID)
            terminationStatusesByScriptID.removeValue(forKey: selectedScriptID)
        }
        updateDisplayedOutput()
        savePersistedOutputs()
    }

    func sendInput(_ input: String) {
        guard process?.isRunning == true, let inputPipe else { return }
        let line = input + "\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
            if let runningScriptID { appendOutput("\(input)\n", for: runningScriptID) }
        } catch {
            if let runningScriptID {
                appendOutput("\n[Не удалось отправить ввод: \(error.localizedDescription)]\n", for: runningScriptID)
            }
        }
    }

    private func setOutput(_ value: String, for scriptID: String) {
        outputsByScriptID[scriptID] = value
        if selectedScriptID == scriptID { output = value }
        scheduleOutputPersistence()
    }

    private func appendOutput(_ value: String, for scriptID: String) {
        outputsByScriptID[scriptID, default: ""] += value
        if selectedScriptID == scriptID { output = outputsByScriptID[scriptID] ?? Self.emptyOutputMessage }
        scheduleOutputPersistence()
    }

    private func updateDisplayedOutput() {
        guard let selectedScriptID else {
            output = Self.emptyOutputMessage
            terminationStatus = nil
            return
        }
        output = outputsByScriptID[selectedScriptID] ?? Self.emptyOutputMessage
        terminationStatus = terminationStatusesByScriptID[selectedScriptID]
    }

    private func notes() -> [String: String] {
        defaults.dictionary(forKey: notesKey) as? [String: String] ?? [:]
    }

    private func saveCurrentOrder() {
        defaults.set(scripts.map(\.id), forKey: orderKey)
    }

    private func loadGroups() {
        guard let data = defaults.data(forKey: groupsKey),
              let storedGroups = try? JSONDecoder().decode([ScriptGroup].self, from: data) else { return }
        groups = storedGroups
    }

    private func saveGroups() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        defaults.set(data, forKey: groupsKey)
    }

    private var outputStateURL: URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return applicationSupport
            .appendingPathComponent("MacScriptRunner", isDirectory: true)
            .appendingPathComponent("terminal-state.json")
    }

    private func loadPersistedOutputs() {
        guard let outputStateURL,
              let data = try? Data(contentsOf: outputStateURL),
              let state = try? JSONDecoder().decode(PersistedTerminalState.self, from: data) else { return }
        outputsByScriptID = state.outputs
        terminationStatusesByScriptID = state.terminationStatuses
        lastRunDatesByScriptID = state.lastRunDates ?? [:]
    }

    private func scheduleOutputPersistence() {
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.savePersistedOutputs()
        }
    }

    private func savePersistedOutputs() {
        guard let outputStateURL else { return }
        let state = PersistedTerminalState(
            outputs: outputsByScriptID,
            terminationStatuses: terminationStatusesByScriptID,
            lastRunDates: lastRunDatesByScriptID
        )
        do {
            try FileManager.default.createDirectory(
                at: outputStateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: outputStateURL, options: .atomic)
        } catch {
            // A persistence failure must not interrupt a running script.
        }
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
