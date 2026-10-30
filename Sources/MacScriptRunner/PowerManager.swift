import Foundation
import ServiceManagement

/// Keeps MacScriptRunner available for the Telegram bot: launch at login and
/// staying awake with the lid closed (`pmset disablesleep`, needs an administrator password).
@MainActor
final class PowerManager: ObservableObject {
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginNeedsApproval = false
    @Published private(set) var sleepDisabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchAtLoginNeedsApproval = status == .requiresApproval
        sleepDisabled = Self.readSleepDisabled()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        message = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            message = "Не удалось изменить автозапуск: \(error.localizedDescription)"
        }
        refresh()
        if launchAtLoginNeedsApproval {
            message = "Разрешите автозапуск в Системных настройках → Основные → Объекты входа."
        }
    }

    func setSleepDisabled(_ disabled: Bool) {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        Task {
            let result = await Task.detached { Self.runPmsetAsAdministrator(disableSleep: disabled) }.value
            isBusy = false
            if let result { message = result }
            refresh()
        }
    }

    // MARK: - pmset

    private nonisolated static func readSleepDisabled() -> Bool {
        guard let output = run("/usr/bin/pmset", ["-g"])?.output else { return false }
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        return false
    }

    /// Returns an error message, or nil on success. Shows the standard macOS password dialog.
    private nonisolated static func runPmsetAsAdministrator(disableSleep: Bool) -> String? {
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(disableSleep ? 1 : 0)\" with administrator privileges"
        guard let result = run("/usr/bin/osascript", ["-e", script]) else {
            return "Не удалось запустить osascript"
        }
        if result.status == 0 { return nil }
        if result.output.contains("-128") { return "Отменено" }
        return "Ошибка pmset: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private nonisolated static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
