import AppKit
import Combine
import Foundation
import ServiceManagement

/// Paths and scripts of the "power guard": a root LaunchDaemon that keeps the Mac awake on AC power
/// (and while the bot is busy), lets it sleep on battery and schedules periodic wake-ups.
private enum PowerGuard {
    static let label = "local.macscriptrunner.powerguard"
    static let plistPath = "/Library/LaunchDaemons/local.macscriptrunner.powerguard.plist"
    static let supportPath = "/Library/Application Support/MacScriptRunner"
    static let sharedPath = "/Users/Shared/MacScriptRunner"

    /// Runs as root every 10 seconds and right after every wake.
    static let guardScript = #"""
    #!/bin/bash
    # MacScriptRunner power guard (installed from MacScriptRunner → Settings → Работа в фоне).
    SUPPORT="/Library/Application Support/MacScriptRunner"
    SHARED="/Users/Shared/MacScriptRunner"
    now=$(date +%s)

    app_running=0
    pgrep -x MacScriptRunner >/dev/null 2>&1 && app_running=1
    on_ac=0
    pmset -g ps | head -n 1 | grep -q "AC Power" && on_ac=1
    lid_closed=0
    ioreg -r -k AppleClamshellState -d 1 | grep -q '"AppleClamshellState" = Yes' && lid_closed=1
    battery=$(pmset -g batt | grep -Eo '[0-9]+%' | head -n 1 | tr -d '%')
    battery=${battery:-100}

    # The app touches the busy file while a script runs or the bot is talking to someone.
    busy=0
    if [ -f "$SHARED/busy" ]; then
      modified=$(stat -f %m "$SHARED/busy")
      [ $((now - modified)) -lt 40 ] && busy=1
    fi
    waketime=$(sysctl -n kern.waketime 2>/dev/null | sed -E 's/^\{ sec = ([0-9]+).*/\1/')
    case "$waketime" in ''|*[!0-9]*) waketime=0 ;; esac
    [ "$waketime" -gt 0 ] && [ $((now - waketime)) -lt 60 ] && busy=1

    # 1. No sleep on AC power, or on battery while busy (unless the battery is almost empty).
    desired=0
    if [ "$app_running" = 1 ]; then
      if [ "$on_ac" = 1 ] || { [ "$busy" = 1 ] && [ "$battery" -gt 10 ]; }; then desired=1; fi
    fi
    current=$(pmset -g | awk '/SleepDisabled/ {print $2}')
    current=${current:-0}
    [ "$current" != "$desired" ] && pmset -a disablesleep "$desired"

    # 2. On battery keep one wake-up scheduled a few minutes ahead.
    interval=$(cat "$SHARED/wake-interval" 2>/dev/null | tr -cd '0-9')
    interval=${interval:-0}
    [ "$interval" -gt 1440 ] && interval=1440
    next=$(cat "$SUPPORT/next-wake" 2>/dev/null | tr -cd '0-9'); next=${next:-0}
    last=$(cat "$SUPPORT/last-wake" 2>/dev/null | tr -cd '0-9'); last=${last:-0}
    if [ "$app_running" = 1 ] && [ "$interval" -ge 1 ] && [ "$on_ac" = 0 ] && [ "$battery" -gt 10 ]; then
      if [ "$next" -le "$now" ]; then
        if [ "$next" -gt 0 ]; then echo "$next" > "$SUPPORT/last-wake"; last=$next; fi
        next=$((now + interval * 60))
        if pmset schedule wake "$(date -r "$next" '+%m/%d/%y %H:%M:%S')" >/dev/null 2>&1; then
          echo "$next" > "$SUPPORT/next-wake"
        fi
      fi
    fi

    # After one of our wake-ups: back to sleep once the bot has nothing to do.
    ours=0
    for t in "$last" "$next"; do
      if [ "$t" -gt 0 ] && [ "$waketime" -gt 0 ]; then
        d=$((waketime - t))
        [ "${d#-}" -lt 120 ] && ours=1
      fi
    done
    if [ "$ours" = 1 ] && [ "$on_ac" = 0 ] && [ "$lid_closed" = 1 ] && [ "$busy" = 0 ]; then
      pmset sleepnow >/dev/null 2>&1
    fi
    exit 0
    """#

    static let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>\(label)</string>
      <key>ProgramArguments</key><array>
        <string>/bin/bash</string>
        <string>\(supportPath)/power-guard.sh</string>
      </array>
      <key>StartInterval</key><integer>10</integer>
      <key>RunAtLoad</key><true/>
    </dict></plist>
    """

    static var installScript: String {
        """
        set -e
        SUPPORT='\(supportPath)'
        mkdir -p "$SUPPORT" '\(sharedPath)'
        chmod 1777 '\(sharedPath)'
        cat > "$SUPPORT/power-guard.sh" <<'MSR_GUARD'
        \(guardScript)
        MSR_GUARD
        chown root:wheel "$SUPPORT/power-guard.sh"
        chmod 755 "$SUPPORT/power-guard.sh"
        cat > '\(plistPath)' <<'MSR_PLIST'
        \(plist)
        MSR_PLIST
        chown root:wheel '\(plistPath)'
        chmod 644 '\(plistPath)'
        launchctl bootout system/\(label) 2>/dev/null || true
        launchctl bootstrap system '\(plistPath)'
        """
    }

    static var uninstallScript: String {
        """
        SUPPORT='\(supportPath)'
        launchctl bootout system/\(label) 2>/dev/null || true
        rm -f '\(plistPath)'
        next=$(cat "$SUPPORT/next-wake" 2>/dev/null | tr -cd '0-9')
        if [ -n "$next" ]; then
          pmset schedule cancel wake "$(date -r "$next" '+%m/%d/%y %H:%M:%S')" >/dev/null 2>&1 || true
        fi
        rm -rf "$SUPPORT"
        pmset -a disablesleep 0
        exit 0
        """
    }
}

/// Keeps MacScriptRunner available for the Telegram bot: launch at login and the power guard.
@MainActor
final class PowerManager: ObservableObject {
    static let wakeIntervalChoices = [0, 5, 10, 15, 30, 60]
    private static let wakeIntervalKey = "powerWakeIntervalMinutes"

    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginNeedsApproval = false
    @Published private(set) var isGuardInstalled = false
    @Published private(set) var sleepDisabled = false
    @Published private(set) var onACPower = true
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?
    @Published var wakeIntervalMinutes: Int {
        didSet {
            guard oldValue != wakeIntervalMinutes else { return }
            UserDefaults.standard.set(wakeIntervalMinutes, forKey: Self.wakeIntervalKey)
            writeWakeInterval()
        }
    }

    private let library: ScriptLibrary
    private let bot: TelegramBot
    private var lastWake = Date.distantPast
    private var heartbeatTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private var sharedDirectory: URL { URL(fileURLWithPath: PowerGuard.sharedPath, isDirectory: true) }

    init(library: ScriptLibrary, bot: TelegramBot) {
        self.library = library
        self.bot = bot
        let stored = UserDefaults.standard.object(forKey: Self.wakeIntervalKey) as? Int ?? 10
        self.wakeIntervalMinutes = Self.wakeIntervalChoices.contains(stored) ? stored : 10
        writeWakeInterval()
        refresh()

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.lastWake = Date()
                    self?.tick()
                }
            }
            .store(in: &cancellables)
        library.$runningScriptID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            .store(in: &cancellables)

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    // MARK: - Status

    func refresh() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchAtLoginNeedsApproval = status == .requiresApproval
        isGuardInstalled = FileManager.default.fileExists(atPath: PowerGuard.plistPath)
        sleepDisabled = Self.readSleepDisabled()
        onACPower = Self.readOnACPower()
    }

    var powerSummary: String {
        let source = onACPower ? "от сети" : "от батареи"
        let sleep = sleepDisabled ? "сон отключён" : "сон разрешён"
        return "Сейчас: \(source), \(sleep)"
    }

    // MARK: - Launch at login

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

    // MARK: - Power guard

    func setGuardInstalled(_ install: Bool) {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        writeWakeInterval()
        let script = install ? PowerGuard.installScript : PowerGuard.uninstallScript
        Task {
            let error = await Task.detached { Self.runAsAdministrator(script) }.value
            isWorking = false
            message = error
            refresh()
        }
    }

    /// Tells the guard that the Mac must stay awake for now (fresh for ~40 s).
    private func tick() {
        let now = Date()
        let busy = library.runningScriptID != nil
            || now.timeIntervalSince(bot.lastActivity) < 120
            || now.timeIntervalSince(lastWake) < 45
        guard busy else { return }
        try? FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        try? Data().write(to: sharedDirectory.appendingPathComponent("busy"))
    }

    private func writeWakeInterval() {
        try? FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        try? Data("\(wakeIntervalMinutes)\n".utf8).write(to: sharedDirectory.appendingPathComponent("wake-interval"))
    }

    // MARK: - Shell helpers

    private nonisolated static func readSleepDisabled() -> Bool {
        guard let output = run("/usr/bin/pmset", ["-g"])?.output else { return false }
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        return false
    }

    private nonisolated static func readOnACPower() -> Bool {
        guard let output = run("/usr/bin/pmset", ["-g", "ps"])?.output else { return true }
        return output.split(separator: "\n").first?.contains("AC Power") ?? true
    }

    /// Runs a bash script as root through the standard macOS password dialog. Returns an error message or nil.
    private nonisolated static func runAsAdministrator(_ script: String) -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("msr-\(UUID().uuidString).sh")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return "Не удалось подготовить установку: \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let appleScript = "do shell script \"/bin/bash \" & quoted form of \"\(url.path)\" with administrator privileges"
        guard let result = run("/usr/bin/osascript", ["-e", appleScript]) else {
            return "Не удалось запустить osascript"
        }
        if result.status == 0 { return nil }
        if result.output.contains("-128") { return "Отменено" }
        return "Ошибка: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
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
