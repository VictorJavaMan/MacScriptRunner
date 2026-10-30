import AppKit
import Combine
import CryptoKit
import Foundation
import Security
import SystemConfiguration

// MARK: - Telegram Bot API models

private struct TGResponse<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
    let description: String?
    let errorCode: Int?
    let parameters: TGResponseParameters?
}

private struct TGResponseParameters: Decodable {
    let retryAfter: Int?
}

private struct TGUpdate: Decodable {
    let updateId: Int
    let message: TGMessage?
    let callbackQuery: TGCallbackQuery?
}

private struct TGMessage: Decodable {
    let messageId: Int
    let date: Int?
    let chat: TGChat
    let from: TGUser?
    let text: String?
}

private struct TGChat: Decodable {
    let id: Int64
    let type: String
}

private struct TGUser: Decodable {
    let id: Int64
    let firstName: String?
    let lastName: String?
    let username: String?

    var displayName: String {
        let full = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        if let username, !username.isEmpty { return full.isEmpty ? "@\(username)" : "\(full) (@\(username))" }
        return full.isEmpty ? "id \(id)" : full
    }
}

private struct TGCallbackQuery: Decodable {
    let id: String
    let from: TGUser
    let message: TGMessage?
    let data: String?
}

private struct TGBotInfo: Decodable {
    let username: String?
}

/// Decodes a list of updates, skipping ones that cannot be parsed so the offset still advances.
private struct TGUpdateBatch: Decodable {
    let updates: [TGUpdate]
    let lastUpdateID: Int?

    private struct UpdateID: Decodable {
        let updateId: Int
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var updates: [TGUpdate] = []
        var lastID: Int?
        while !container.isAtEnd {
            if let update = try? container.decode(TGUpdate.self) {
                updates.append(update)
                lastID = update.updateId
            } else if let raw = try? container.decode(UpdateID.self) {
                lastID = raw.updateId
            } else {
                _ = try? container.decode(TGIgnored.self)
            }
        }
        self.updates = updates
        self.lastUpdateID = lastID
    }
}

/// Accepts any `result` value when the caller does not need it.
private struct TGIgnored: Decodable {
    init(from decoder: Decoder) throws {}
}

private struct TelegramError: Error {
    let code: Int?
    let message: String
    let retryAfter: Int?
}

/// Telegram user that entered the access code and may control the Mac.
struct TelegramAuthorizedUser: Identifiable, Hashable {
    let id: Int64
    let name: String
}

private enum TokenKeychain {
    private static var base: [String: Any] {
        [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "MacScriptRunner.TelegramBot",
        kSecAttrAccount as String: "botToken"
        ]
    }

    static func read() -> String {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ token: String) {
        SecItemDelete(base as CFDictionary)
        guard !token.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Telegram bot embedded in the app. It long-polls the Bot API with outgoing HTTPS requests,
/// so it works from any network without servers or port forwarding.
@MainActor
final class TelegramBot: ObservableObject {
    private typealias Keyboard = [[[String: String]]]

    private struct LiveRun {
        let chatID: Int64
        let messageID: Int
        var isDirty = false
        var stopRequested = false
    }

    private enum Keys {
        static let enabled = "telegramBotEnabled"
        static let users = "telegramAuthorizedUsers"
        static let offset = "telegramUpdateOffset"
        static let code = "remoteAccessCode"
        static let keepAwake = "telegramKeepAwake"
    }

    private static let maxShownCharacters = 3_300
    private static let ansiExpression = try? NSRegularExpression(
        pattern: "\u{1B}(\\[[0-?]*[ -/]*[@-~]|\\][^\u{07}]*\u{07}|[@-Z\\\\-_])"
    )

    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            restart()
        }
    }
    /// Prevents idle sleep while the bot is on (the display may still turn off).
    @Published var keepAwake: Bool {
        didSet {
            guard oldValue != keepAwake else { return }
            defaults.set(keepAwake, forKey: Keys.keepAwake)
            if activity != nil {
                endActivity()
                beginActivity()
            }
        }
    }
    @Published private(set) var statusText = "Выключен"
    @Published private(set) var botUsername: String?
    @Published private(set) var hasToken: Bool
    @Published private(set) var authorizedUsers: [TelegramAuthorizedUser] = []
    @Published private(set) var accessCode: String

    let hostName: String

    var formattedAccessCode: String {
        let characters = Array(accessCode)
        return stride(from: 0, to: characters.count, by: 3)
            .map { String(characters[$0..<min($0 + 3, characters.count)]) }
            .joined(separator: " ")
    }

    private let library: ScriptLibrary
    private let defaults = UserDefaults.standard
    private let session: URLSession
    private let decoder: JSONDecoder
    private var token: String
    private var activeToken: String?
    private var pollTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var flushInFlight: Task<Void, Never>?
    private var startedAt = Date()
    private var liveRuns: [String: LiveRun] = [:]
    private var pendingArguments: [Int64: String] = [:]
    private var failedAttempts: [Int64: Int] = [:]
    private var lockedUntil: [Int64: Date] = [:]
    private var activity: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    init(library: ScriptLibrary) {
        self.library = library
        let computerName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
        self.hostName = String(computerName.prefix(60))
        if let storedCode = UserDefaults.standard.string(forKey: Keys.code),
           storedCode.count == 9, storedCode.allSatisfy({ $0.isNumber }) {
            self.accessCode = storedCode
        } else {
            self.accessCode = Self.generateCode()
        }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 75
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
        let storedToken = TokenKeychain.read()
        self.token = storedToken
        self.hasToken = !storedToken.isEmpty
        self.isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        self.keepAwake = UserDefaults.standard.object(forKey: Keys.keepAwake) as? Bool ?? true
        loadUsers()
        defaults.set(accessCode, forKey: Keys.code)

        library.outputEvents
            .sink { [weak self] event in
                MainActor.assumeIsolated { self?.handleOutputEvent(event) }
            }
            .store(in: &cancellables)

        // After sleep the pending long-poll request is stale; reconnect right away.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isEnabled else { return }
                    self.restart()
                }
            }
            .store(in: &cancellables)

        restart()
    }

    // MARK: - Settings

    func saveToken(_ rawToken: String) {
        let newToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newToken != token else { return }
        token = newToken
        TokenKeychain.write(newToken)
        hasToken = !newToken.isEmpty
        defaults.removeObject(forKey: Keys.offset)
        restart()
    }

    /// New code for future logins; already authorized accounts keep access until revoked.
    func regenerateAccessCode() {
        accessCode = Self.generateCode()
        defaults.set(accessCode, forKey: Keys.code)
        failedAttempts.removeAll()
        lockedUntil.removeAll()
    }

    private static func generateCode() -> String {
        String(format: "%09ld", Int.random(in: 0..<1_000_000_000))
    }

    func removeUser(_ user: TelegramAuthorizedUser) {
        authorizedUsers.removeAll { $0.id == user.id }
        saveUsers()
        pendingArguments[user.id] = nil
    }

    // MARK: - Polling

    private func restart() {
        pollTask?.cancel()
        pollTask = nil
        activeToken = nil
        botUsername = nil
        guard isEnabled else {
            statusText = "Выключен"
            endActivity()
            return
        }
        guard !token.isEmpty else {
            statusText = "Укажите токен бота"
            endActivity()
            return
        }
        activeToken = token
        startedAt = Date()
        beginActivity()
        statusText = "Подключение к Telegram…"
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            do {
                if botUsername == nil {
                    let info: TGBotInfo = try await call("getMe")
                    botUsername = info.username ?? "bot"
                    let _: TGIgnored = try await call("deleteWebhook")
                    let commands: [[String: String]] = [
                        ["command": "scripts", "description": "Список скриптов"],
                        ["command": "status", "description": "Что сейчас выполняется"],
                        ["command": "stop", "description": "Остановить скрипт"],
                        ["command": "cancel", "description": "Отменить ввод аргументов"],
                        ["command": "logout", "description": "Отключить этот аккаунт"],
                        ["command": "help", "description": "Справка"]
                    ]
                    let _: TGIgnored = try await call("setMyCommands", ["commands": commands])
                    // Commands sent while the app was closed are dropped instead of being executed now.
                    let backlog: TGUpdateBatch = try await call("getUpdates", ["offset": -1, "timeout": 0])
                    if let last = backlog.lastUpdateID { defaults.set(last + 1, forKey: Keys.offset) }
                }
                statusText = "Работает: @\(botUsername ?? "bot")"
                let offset = defaults.integer(forKey: Keys.offset)
                var parameters: [String: Any] = ["timeout": 50, "allowed_updates": ["message", "callback_query"]]
                if offset > 0 { parameters["offset"] = offset }
                let batch: TGUpdateBatch = try await call("getUpdates", parameters, timeout: 70)
                guard !Task.isCancelled else { return }
                // Saved before handling so a crash never replays a command.
                if let last = batch.lastUpdateID { defaults.set(last + 1, forKey: Keys.offset) }
                for update in batch.updates {
                    guard !Task.isCancelled else { return }
                    await handle(update)
                }
            } catch {
                if Task.isCancelled { return }
                if let telegramError = error as? TelegramError {
                    switch telegramError.code {
                    case 401, 404:
                        statusText = "Неверный токен бота"
                        botUsername = nil
                        return
                    case 409:
                        statusText = "Бот уже запущен в другом месте. Повтор…"
                    case 429:
                        try? await Task.sleep(for: .seconds(telegramError.retryAfter ?? 5))
                        continue
                    default:
                        statusText = "Ошибка Telegram: \(telegramError.message)"
                    }
                } else {
                    statusText = "Нет связи с Telegram, повтор…"
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: - Updates

    private func handle(_ update: TGUpdate) async {
        if let callback = update.callbackQuery {
            await handleCallback(callback)
        } else if let message = update.message, let text = message.text {
            if let date = message.date, Date(timeIntervalSince1970: TimeInterval(date)) < startedAt.addingTimeInterval(-60) {
                return
            }
            await handleText(text, message: message)
        }
    }

    private func handleText(_ text: String, message: TGMessage) async {
        guard message.chat.type == "private", let user = message.from else { return }
        let chatID = message.chat.id
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard isAuthorized(user.id) else {
            await handleLogin(trimmed, user: user, chatID: chatID)
            return
        }

        if trimmed.hasPrefix("/") {
            let word = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
            let command = (word.split(separator: "@").first.map(String.init) ?? word).lowercased()
            switch command {
            case "/start", "/scripts", "/list", "/menu":
                pendingArguments[chatID] = nil
                await sendMenu(chatID: chatID)
            case "/stop":
                stopRunning(chatID: chatID)
            case "/status":
                await sendStatus(chatID: chatID)
            case "/cancel":
                pendingArguments[chatID] = nil
                await send(chatID, "Ввод аргументов отменён.")
            case "/logout":
                removeUser(TelegramAuthorizedUser(id: user.id, name: user.displayName))
                await send(chatID, "Доступ для этого аккаунта отключён. Чтобы вернуться, отправьте код доступа.")
            default:
                await send(chatID, Self.helpText)
            }
            return
        }

        if let scriptID = pendingArguments.removeValue(forKey: chatID) {
            await runScript(scriptID, chatID: chatID, arguments: trimmed == "-" ? "" : text)
            return
        }

        if library.runningScriptID != nil {
            library.sendInput(text)
            return
        }
        await send(chatID, "Сейчас ничего не выполняется. /scripts — список скриптов.")
    }

    private func handleLogin(_ text: String, user: TGUser, chatID: Int64) async {
        let candidate = text.hasPrefix("/start") ? String(text.dropFirst(6)) : text
        let digits = candidate.filter { $0.isNumber }
        guard !digits.isEmpty else {
            await send(chatID, "👋 Это бот MacScriptRunner на «\(escape(hostName))».\n\n"
                + "Чтобы получить доступ, отправьте код из MacScriptRunner → Settings → «Удалённый доступ».")
            return
        }
        if let until = lockedUntil[user.id], until > Date() {
            let seconds = max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
            await send(chatID, "Слишком много неверных попыток. Повторите через \(seconds) с.")
            return
        }
        guard Self.constantTimeEquals(digits, accessCode) else {
            let attempts = (failedAttempts[user.id] ?? 0) + 1
            if attempts >= 5 {
                failedAttempts[user.id] = 0
                lockedUntil[user.id] = Date().addingTimeInterval(300)
            } else {
                failedAttempts[user.id] = attempts
            }
            await send(chatID, "❌ Неверный код доступа.")
            return
        }
        failedAttempts[user.id] = nil
        lockedUntil[user.id] = nil
        authorizedUsers.removeAll { $0.id == user.id }
        authorizedUsers.append(TelegramAuthorizedUser(id: user.id, name: user.displayName))
        saveUsers()
        await send(chatID, "✅ Доступ открыт. Теперь вы можете запускать скрипты на «\(escape(hostName))».\n\n" + Self.helpText)
        await sendMenu(chatID: chatID)
    }

    private func handleCallback(_ callback: TGCallbackQuery) async {
        guard let message = callback.message, let data = callback.data else { return }
        guard isAuthorized(callback.from.id) else {
            await answer(callback, text: "Нет доступа. Отправьте код доступа.")
            return
        }
        let chatID = message.chat.id
        let messageID = message.messageId
        let parts = data.split(separator: ":", maxSplits: 1).map(String.init)
        let action = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1] : ""

        switch action {
        case "l":
            await answer(callback)
            await sendMenu(chatID: chatID, editing: messageID)
        case "g":
            await answer(callback)
            await sendGroup(argument, chatID: chatID, editing: messageID)
        case "s":
            await answer(callback)
            await sendScriptCard(argument, chatID: chatID, editing: messageID)
        case "r":
            await answer(callback, text: "Запуск…")
            if let script = script(forShortID: argument) {
                await runScript(script.id, chatID: chatID, arguments: nil)
            } else {
                await send(chatID, "Скрипт не найден. /scripts — обновить список.")
            }
        case "a":
            await answer(callback)
            guard let script = script(forShortID: argument) else { return }
            pendingArguments[chatID] = script.id
            let current = library.arguments(for: script.id)
            let currentLine = current.isEmpty ? "сейчас аргументов нет" : "сейчас: <code>\(escape(current))</code>"
            await send(chatID, "⌨️ Отправьте аргументы для <b>\(escape(script.name))</b> одним сообщением "
                + "(\(currentLine)).\nЗначения с пробелами заключайте в кавычки. «-» — запустить без аргументов, /cancel — отмена.")
        case "o":
            await answer(callback)
            if let script = script(forShortID: argument) { await sendLastOutput(script, chatID: chatID) }
        case "x":
            await answer(callback, text: "Останавливаю…")
            stopRunning(chatID: chatID)
        default:
            await answer(callback)
        }
    }

    // MARK: - Screens

    private func sendMenu(chatID: Int64, editing messageID: Int? = nil) async {
        var keyboard: Keyboard = []
        var text = "🖥 <b>\(escape(hostName))</b>\n"
        if let running = library.runningScriptID.flatMap({ library.script(withID: $0) }) {
            text += "⏳ Выполняется: <b>\(escape(running.name))</b>\n"
            keyboard.append([button("⏹ Остановить \(running.name)", "x")])
        }
        if library.scripts.isEmpty {
            text += "\nСкриптов нет. Добавьте папку со .sh-файлами в настройках MacScriptRunner."
        } else {
            text += "\nВыберите скрипт:"
        }
        for group in library.groups {
            let count = library.scripts(in: group).count
            keyboard.append([button("📁 \(group.name) (\(count))", "g:\(group.id.uuidString)")])
        }
        for script in library.ungroupedScripts {
            keyboard.append([scriptButton(script)])
        }
        keyboard.append([button("🔄 Обновить", "l")])
        await show(chatID: chatID, editing: messageID, text: text, keyboard: Array(keyboard.prefix(95)))
    }

    private func sendGroup(_ groupID: String, chatID: Int64, editing messageID: Int?) async {
        guard let group = library.groups.first(where: { $0.id.uuidString == groupID }) else {
            await sendMenu(chatID: chatID, editing: messageID)
            return
        }
        var keyboard: Keyboard = library.scripts(in: group).map { [scriptButton($0)] }
        keyboard.append([button("« Назад", "l")])
        let text = "📁 <b>\(escape(group.name))</b>\nВыберите скрипт:"
        await show(chatID: chatID, editing: messageID, text: text, keyboard: Array(keyboard.prefix(95)))
    }

    private func sendScriptCard(_ shortID: String, chatID: Int64, editing messageID: Int?) async {
        guard let script = script(forShortID: shortID) else {
            await sendMenu(chatID: chatID, editing: messageID)
            return
        }
        let isRunning = library.runningScriptID == script.id
        var lines = ["📜 <b>\(escape(script.name))</b>"]
        let note = library.note(for: script)
        if !note.isEmpty { lines.append("<i>\(escape(note))</i>") }
        if isRunning {
            lines.append("⏳ Выполняется")
        } else if let date = library.lastRunDate(for: script) {
            var line = "Последний запуск: \(date.formatted(date: .abbreviated, time: .shortened))"
            if let status = library.storedTerminationStatus(forScriptID: script.id) {
                line += status == 0 ? " · ✅ код 0" : " · ❌ код \(status)"
            }
            lines.append(line)
        } else {
            lines.append("Ещё не запускался")
        }
        let arguments = library.arguments(for: script.id)
        if !arguments.isEmpty { lines.append("Аргументы: <code>\(escape(arguments))</code>") }

        let sid = Self.shortID(script.id)
        var keyboard: Keyboard = []
        if isRunning {
            keyboard.append([button("⏹ Остановить", "x")])
        } else {
            keyboard.append([button("▶️ Запустить", "r:\(sid)"), button("⌨️ С аргументами", "a:\(sid)")])
        }
        keyboard.append([button("📄 Последний вывод", "o:\(sid)")])
        let backAction = library.groupID(for: script).map { "g:\($0.uuidString)" } ?? "l"
        keyboard.append([button("« Назад", backAction)])
        await show(chatID: chatID, editing: messageID, text: lines.joined(separator: "\n"), keyboard: keyboard)
    }

    private func sendStatus(chatID: Int64) async {
        if let running = library.runningScriptID.flatMap({ library.script(withID: $0) }) {
            let output = library.storedOutput(forScriptID: running.id) ?? ""
            await show(
                chatID: chatID,
                editing: nil,
                text: outputText(header: "⏳ <b>\(escape(running.name))</b> выполняется", output: output),
                keyboard: [[button("⏹ Остановить", "x")]]
            )
        } else {
            await send(chatID, "Сейчас ничего не выполняется. /scripts — список скриптов.")
        }
    }

    private func sendLastOutput(_ script: ScriptItem, chatID: Int64) async {
        guard let output = library.storedOutput(forScriptID: script.id), !output.isEmpty else {
            await send(chatID, "У скрипта <b>\(escape(script.name))</b> нет сохранённого вывода.")
            return
        }
        await send(chatID, outputText(header: "📄 <b>\(escape(script.name))</b>", output: output))
        await sendFullOutputIfNeeded(script, output: output, chatID: chatID)
    }

    // MARK: - Running scripts

    private func runScript(_ scriptID: String, chatID: Int64, arguments: String?) async {
        guard let script = library.script(withID: scriptID) else {
            await send(chatID, "Скрипт не найден. /scripts — обновить список.")
            return
        }
        if let arguments { library.setArguments(arguments, for: scriptID) }
        if liveRuns[scriptID] != nil { await finishLiveRun(scriptID) }
        if let error = library.startScript(script) {
            await send(chatID, "⚠️ \(escape(error))")
            return
        }
        let output = library.storedOutput(forScriptID: scriptID) ?? ""
        guard let message = try? await sendMessage(
            chatID,
            outputText(header: "⏳ <b>\(escape(script.name))</b> выполняется…", output: output),
            keyboard: [[button("⏹ Остановить", "x")]]
        ) else {
            await send(chatID, "Скрипт <b>\(escape(script.name))</b> запущен, но вывод не удалось показать. /status — проверить.")
            return
        }
        liveRuns[scriptID] = LiveRun(chatID: chatID, messageID: message.messageId)
        // Fast scripts may finish while the message is being sent.
        if library.runningScriptID != scriptID {
            await finishLiveRun(scriptID)
        } else {
            liveRuns[scriptID]?.isDirty = true
            scheduleFlush()
        }
    }

    private func stopRunning(chatID: Int64) {
        if library.runningScriptID == nil {
            Task { await send(chatID, "Сейчас ничего не выполняется.") }
        } else {
            if let runningID = library.runningScriptID { liveRuns[runningID]?.stopRequested = true }
            library.stopRunningScript()
        }
    }

    private func handleOutputEvent(_ event: ScriptOutputEvent) {
        switch event {
        case let .appended(scriptID, _), let .replaced(scriptID, _):
            guard liveRuns[scriptID] != nil else { return }
            liveRuns[scriptID]?.isDirty = true
            scheduleFlush()
        case let .finished(scriptID, _):
            // A restart of the same script also ends the previous process; keep the live message then.
            guard liveRuns[scriptID] != nil, library.runningScriptID != scriptID else { return }
            Task { await finishLiveRun(scriptID) }
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self else { return }
            await self.flushInFlight?.value
            let flush = Task { await self.flushLiveRuns() }
            self.flushInFlight = flush
            await flush.value
            self.flushInFlight = nil
            self.flushTask = nil
        }
    }

    private func flushLiveRuns() async {
        for (scriptID, run) in liveRuns where run.isDirty {
            guard liveRuns[scriptID]?.messageID == run.messageID else { continue }
            liveRuns[scriptID]?.isDirty = false
            guard let script = library.script(withID: scriptID) else { continue }
            let output = library.storedOutput(forScriptID: scriptID) ?? ""
            await edit(
                chatID: run.chatID,
                messageID: run.messageID,
                text: outputText(header: "⏳ <b>\(escape(script.name))</b> выполняется…", output: output),
                keyboard: [[button("⏹ Остановить", "x")]]
            )
        }
    }

    private func finishLiveRun(_ scriptID: String) async {
        guard let run = liveRuns.removeValue(forKey: scriptID) else { return }
        await flushInFlight?.value
        let output = library.storedOutput(forScriptID: scriptID) ?? ""
        let name = library.script(withID: scriptID)?.name ?? URL(fileURLWithPath: scriptID).lastPathComponent
        let status = library.storedTerminationStatus(forScriptID: scriptID)
        let header: String
        switch run.stopRequested ? nil : status {
        case 0?: header = "✅ <b>\(escape(name))</b> — завершён (код 0)"
        case let code?: header = "❌ <b>\(escape(name))</b> — завершён с кодом \(code)"
        case nil: header = "⏹ <b>\(escape(name))</b> — остановлен"
        }
        let sid = Self.shortID(scriptID)
        await edit(
            chatID: run.chatID,
            messageID: run.messageID,
            text: outputText(header: header, output: output),
            keyboard: [[button("🔁 Ещё раз", "r:\(sid)"), button("📜 К скрипту", "s:\(sid)")], [button("📋 Все скрипты", "l")]]
        )
        if let script = library.script(withID: scriptID) {
            await sendFullOutputIfNeeded(script, output: output, chatID: run.chatID)
        }
    }

    private func sendFullOutputIfNeeded(_ script: ScriptItem, output: String, chatID: Int64) async {
        let clean = Self.stripANSI(output)
        guard clean.count > Self.maxShownCharacters else { return }
        try? await sendDocument(
            chatID: chatID,
            fileName: "\(script.name)-output.txt",
            data: Data(clean.utf8),
            caption: "Полный вывод «\(script.name)»"
        )
    }

    // MARK: - Formatting

    private func outputText(header: String, output: String) -> String {
        var clean = Self.stripANSI(output).replacingOccurrences(of: "\r\n", with: "\n")
        clean = clean.trimmingCharacters(in: .newlines)
        for budget in stride(from: Self.maxShownCharacters, through: 300, by: -500) {
            let tail = clean.count > budget ? "…\n" + String(clean.suffix(budget)) : clean
            let body = escape(tail.isEmpty ? "(вывода пока нет)" : tail)
            if header.utf16.count + body.utf16.count <= 4_000 { return "\(header)\n<pre>\(body)</pre>" }
        }
        return "\(header)\n<pre>…</pre>"
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func stripANSI(_ text: String) -> String {
        guard let ansiExpression else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return ansiExpression.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private func button(_ title: String, _ data: String) -> [String: String] {
        ["text": String(title.prefix(60)), "callback_data": data]
    }

    private func scriptButton(_ script: ScriptItem) -> [String: String] {
        let icon = library.runningScriptID == script.id ? "⏳" : "▶️"
        return button("\(icon) \(script.name)", "s:\(Self.shortID(script.id))")
    }

    private func script(forShortID shortID: String) -> ScriptItem? {
        library.scripts.first { Self.shortID($0.id) == shortID }
    }

    /// Callback data is limited to 64 bytes, so scripts are addressed by a hash of their path.
    private static func shortID(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static let helpText = """
    <b>Как пользоваться</b>
    /scripts — список скриптов и групп
    Нажмите на скрипт → ▶️ Запустить. Вывод обновляется в сообщении в реальном времени.
    Пока скрипт работает, любое обычное сообщение отправляется ему в stdin.
    /status — что сейчас выполняется
    /stop — остановить скрипт
    /logout — отключить этот аккаунт
    """

    // MARK: - Authorization

    private func isAuthorized(_ userID: Int64) -> Bool {
        authorizedUsers.contains { $0.id == userID }
    }

    private func loadUsers() {
        let stored = defaults.dictionary(forKey: Keys.users) as? [String: String] ?? [:]
        authorizedUsers = stored.compactMap { key, name in
            Int64(key).map { TelegramAuthorizedUser(id: $0, name: name) }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func saveUsers() {
        var stored: [String: String] = [:]
        for user in authorizedUsers { stored[String(user.id)] = user.name }
        defaults.set(stored, forKey: Keys.users)
    }

    private static func constantTimeEquals(_ left: String, _ right: String) -> Bool {
        let leftBytes = Array(left.utf8)
        let rightBytes = Array(right.utf8)
        guard leftBytes.count == rightBytes.count, !leftBytes.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in leftBytes.indices { difference |= leftBytes[index] ^ rightBytes[index] }
        return difference == 0
    }

    // MARK: - Bot API

    private func send(_ chatID: Int64, _ text: String) async {
        _ = try? await sendMessage(chatID, text, keyboard: nil)
    }

    private func show(chatID: Int64, editing messageID: Int?, text: String, keyboard: Keyboard) async {
        if let messageID {
            await edit(chatID: chatID, messageID: messageID, text: text, keyboard: keyboard)
        } else {
            _ = try? await sendMessage(chatID, text, keyboard: keyboard)
        }
    }

    private func sendMessage(_ chatID: Int64, _ text: String, keyboard: Keyboard?) async throws -> TGMessage {
        var parameters: [String: Any] = [
            "chat_id": chatID,
            "text": text,
            "parse_mode": "HTML",
            "disable_web_page_preview": true
        ]
        if let keyboard { parameters["reply_markup"] = ["inline_keyboard": keyboard] }
        return try await call("sendMessage", parameters)
    }

    private func edit(chatID: Int64, messageID: Int, text: String, keyboard: Keyboard?) async {
        var parameters: [String: Any] = [
            "chat_id": chatID,
            "message_id": messageID,
            "text": text,
            "parse_mode": "HTML",
            "disable_web_page_preview": true
        ]
        if let keyboard { parameters["reply_markup"] = ["inline_keyboard": keyboard] }
        // "message is not modified" and similar errors are harmless here.
        let _: TGIgnored? = try? await call("editMessageText", parameters)
    }

    private func answer(_ callback: TGCallbackQuery, text: String? = nil) async {
        var parameters: [String: Any] = ["callback_query_id": callback.id]
        if let text { parameters["text"] = text }
        let _: TGIgnored? = try? await call("answerCallbackQuery", parameters)
    }

    private func sendDocument(chatID: Int64, fileName: String, data: Data, caption: String) async throws {
        guard let activeToken, let url = URL(string: "https://api.telegram.org/bot\(activeToken)/sendDocument") else { return }
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        appendField("chat_id", String(chatID))
        appendField("caption", caption)
        let safeName = fileName.replacingOccurrences(of: "\"", with: "'")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"document\"; filename=\"\(safeName)\"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let _: TGIgnored = try await perform(request)
    }

    private func call<Result: Decodable>(
        _ method: String,
        _ parameters: [String: Any] = [:],
        timeout: TimeInterval = 30
    ) async throws -> Result {
        guard let activeToken, let url = URL(string: "https://api.telegram.org/bot\(activeToken)/\(method)") else {
            throw TelegramError(code: nil, message: "Нет токена", retryAfter: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
        return try await perform(request)
    }

    private func perform<Result: Decodable>(_ request: URLRequest) async throws -> Result {
        let (data, _) = try await session.data(for: request)
        let response = try decoder.decode(TGResponse<Result>.self, from: data)
        guard response.ok, let result = response.result else {
            throw TelegramError(
                code: response.errorCode,
                message: response.description ?? "неизвестная ошибка",
                retryAfter: response.parameters?.retryAfter
            )
        }
        return result
    }

    // MARK: - App Nap

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: keepAwake ? [.userInitiated] : [.userInitiatedAllowingIdleSystemSleep],
            reason: "Telegram-бот MacScriptRunner"
        )
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
