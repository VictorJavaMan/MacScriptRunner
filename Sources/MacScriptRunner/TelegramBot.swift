import AppKit
import Combine
import CryptoKit
import Foundation
@preconcurrency import Network
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
    let webAppData: TGWebAppData?
}

/// Data sent by the Mini App with `Telegram.WebApp.sendData`.
private struct TGWebAppData: Decodable {
    let data: String
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

/// How the bot shows the result of a finished script.
enum TelegramOutputFormat: String, CaseIterable, Identifiable {
    case image, text, both

    var id: String { rawValue }
    var title: String {
        switch self {
        case .image: "Картинка"
        case .text: "Текст"
        case .both: "Текст и картинка"
        }
    }
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
        static let outputFormat = "telegramOutputFormat"
        static let pending = "telegramPendingArguments"
        static let labels = "telegramKeyboardLabels"
        static let keyboardSignature = "telegramKeyboardSignature"
        static let miniAppURL = "telegramMiniAppURL"
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
    @Published var outputFormat: TelegramOutputFormat {
        didSet { defaults.set(outputFormat.rawValue, forKey: Keys.outputFormat) }
    }
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
    /// HTTPS address of the published miniapp/index.html; empty when the Mini App is not used.
    @Published private(set) var miniAppURL: String

    let hostName: String

    var formattedAccessCode: String {
        let characters = Array(accessCode)
        return stride(from: 0, to: characters.count, by: 3)
            .map { String(characters[$0..<min($0 + 3, characters.count)]) }
            .joined(separator: " ")
    }

    private let library: ScriptLibrary
    private let defaults = UserDefaults.standard
    private var session: URLSession
    private let decoder: JSONDecoder
    private var token: String
    private var activeToken: String?
    private var pollTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var flushInFlight: Task<Void, Never>?
    private let startedAt = Date()
    private var didDropBacklog = false
    /// Last time somebody talked to the bot; the power guard keeps the Mac awake for a while after it.
    private(set) var lastActivity = Date.distantPast
    private var liveRuns: [String: LiveRun] = [:]
    /// Chats waiting for arguments (chat → script path). Persisted so the choice survives restarts.
    private var pendingArguments: [Int64: String] = [:] {
        didSet {
            var stored: [String: String] = [:]
            for (chatID, scriptID) in pendingArguments { stored[String(chatID)] = scriptID }
            defaults.set(stored, forKey: Keys.pending)
        }
    }
    /// Reply-keyboard label → script path. The keyboard lives on the phone, so pressing a button works
    /// even while the Mac sleeps: the message waits in Telegram and is resolved through this cache on wake.
    private var keyboardLabels: [String: String] = [:]
    private var keyboardDirty = false
    private var isPushingKeyboard = false
    private var failedAttempts: [Int64: Int] = [:]
    private var lockedUntil: [Int64: Date] = [:]
    private var activity: NSObjectProtocol?

    // Network resilience
    private let pathMonitor = NWPathMonitor()
    private var networkAvailable = true
    private var pathSignature = ""
    private var lastRestart = Date.distantPast
    private var lastPollSuccess = Date.distantPast
    private var lastWake = Date.distantPast
    private var retryDelay: TimeInterval = 2
    private var watchdogTask: Task<Void, Never>?
    /// Messages, photos and files that are waiting for the network to come back.
    private(set) var pendingDeliveries = 0

    /// True while the Mac should stay awake for the bot: something is still being delivered,
    /// or the bot has not reached Telegram since the last wake-up (at most 3 minutes after it).
    var needsNetworkTime: Bool {
        if pendingDeliveries > 0 { return true }
        guard isEnabled, !token.isEmpty else { return false }
        return lastPollSuccess < lastWake && Date().timeIntervalSince(lastWake) < 180
    }
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
        self.session = Self.makeSession()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
        let storedToken = TokenKeychain.read()
        self.token = storedToken
        self.hasToken = !storedToken.isEmpty
        self.isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        self.keepAwake = UserDefaults.standard.object(forKey: Keys.keepAwake) as? Bool ?? true
        self.miniAppURL = UserDefaults.standard.string(forKey: Keys.miniAppURL) ?? ""
        self.outputFormat = UserDefaults.standard.string(forKey: Keys.outputFormat)
            .flatMap(TelegramOutputFormat.init(rawValue:)) ?? .image
        loadUsers()
        defaults.set(accessCode, forKey: Keys.code)
        let storedPending = defaults.dictionary(forKey: Keys.pending) as? [String: String] ?? [:]
        pendingArguments = Dictionary(uniqueKeysWithValues: storedPending.compactMap { key, value in
            Int64(key).map { ($0, value) }
        })
        keyboardLabels = defaults.dictionary(forKey: Keys.labels) as? [String: String] ?? [:]
        catalogChanged()

        library.objectWillChange
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.catalogChanged() }
            }
            .store(in: &cancellables)

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
                    guard let self else { return }
                    self.lastWake = Date()
                    guard self.isEnabled else { return }
                    self.reconnect(status: "Mac проснулся, переподключение…")
                }
            }
            .store(in: &cancellables)

        // Wi-Fi drops, a new network, VPN on/off: reconnect at once instead of waiting for a timeout.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let interfaces = path.availableInterfaces.map { $0.name }.joined(separator: ",")
            let signature = "\(satisfied)|\(interfaces)|\(path.isExpensive)"
            Task { @MainActor [weak self] in
                self?.networkChanged(satisfied: satisfied, signature: signature)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "MacScriptRunner.TelegramBot.network"))

        // A long-poll request on a silently dead connection can hang; restart if nothing came back in time.
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.checkWatchdog()
            }
        }

        restart()
    }

    // MARK: - Network resilience

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }

    private func networkChanged(satisfied: Bool, signature: String) {
        let previous = pathSignature
        let wasAvailable = networkAvailable
        pathSignature = signature
        networkAvailable = satisfied
        guard !previous.isEmpty, signature != previous, isEnabled, !token.isEmpty else { return }
        if !satisfied {
            statusText = "Нет сети — переподключусь автоматически"
        } else {
            reconnect(status: wasAvailable ? "Сеть сменилась, переподключение…" : "Сеть появилась, переподключение…")
        }
    }

    private func checkWatchdog() {
        guard isEnabled, !token.isEmpty, networkAvailable, botUsername != nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPollSuccess) > 80, now.timeIntervalSince(lastRestart) > 80 else { return }
        reconnect(status: "Нет ответа от Telegram, переподключение…")
    }

    /// Drops all connections (they may belong to the old network) and starts polling again.
    /// Deliveries in progress are retried on the new session.
    private func reconnect(status: String) {
        session.invalidateAndCancel()
        session = Self.makeSession()
        retryDelay = 2
        restart()
        statusText = status
    }

    private static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
                 .secureConnectionFailed, .cannotLoadFromNetwork, .cancelled, .resourceUnavailable:
                return true
            default:
                return false
            }
        }
        if let telegramError = error as? TelegramError {
            guard let code = telegramError.code else { return false }
            return code == 429 || code >= 500
        }
        // An HTML error page from a proxy or Telegram's front end.
        return error is DecodingError
    }

    /// Retries an outgoing request through network outages for up to 10 minutes.
    private func reliably<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        pendingDeliveries += 1
        defer { pendingDeliveries -= 1 }
        let deadline = Date().addingTimeInterval(600)
        var delay: TimeInterval = 2
        while true {
            do {
                return try await operation()
            } catch {
                guard Self.isTransient(error), Date() < deadline, isEnabled else { throw error }
                if let telegramError = error as? TelegramError, let retryAfter = telegramError.retryAfter {
                    delay = TimeInterval(retryAfter)
                }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
    }

    // MARK: - Settings

    func saveToken(_ rawToken: String) {
        let newToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newToken != token else { return }
        token = newToken
        TokenKeychain.write(newToken)
        hasToken = !newToken.isEmpty
        defaults.removeObject(forKey: Keys.offset)
        didDropBacklog = false
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

    /// Returns an error message when the address is not usable.
    func setMiniAppURL(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            guard let components = URLComponents(string: value),
                  components.scheme?.lowercased() == "https",
                  components.host?.isEmpty == false else {
                return "Нужен адрес вида https://…"
            }
        }
        guard value != miniAppURL else { return nil }
        miniAppURL = value
        defaults.set(value, forKey: Keys.miniAppURL)
        keyboardDirty = true
        Task { await pushKeyboardIfNeeded() }
        return nil
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
        lastRestart = Date()
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
                        ["command": "keyboard", "description": "Показать пульт со скриптами"],
                        ["command": "help", "description": "Справка"]
                    ]
                    let _: TGIgnored = try await call("setMyCommands", ["commands": commands])
                }
                if !didDropBacklog {
                    // Commands sent while the app was closed are dropped instead of being executed now.
                    // Commands sent while the Mac slept are kept: they run after the next wake-up.
                    let backlog: TGUpdateBatch = try await call("getUpdates", ["offset": -1, "timeout": 0])
                    if let last = backlog.lastUpdateID { defaults.set(last + 1, forKey: Keys.offset) }
                    didDropBacklog = true
                }
                statusText = "Работает: @\(botUsername ?? "bot")"
                await pushKeyboardIfNeeded()
                let offset = defaults.integer(forKey: Keys.offset)
                // A short long-poll notices a dead connection quickly after a network change.
                var parameters: [String: Any] = ["timeout": 25, "allowed_updates": ["message", "callback_query"]]
                if offset > 0 { parameters["offset"] = offset }
                let batch: TGUpdateBatch = try await call("getUpdates", parameters, timeout: 40)
                guard !Task.isCancelled else { return }
                lastPollSuccess = Date()
                retryDelay = 2
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
                } else if !networkAvailable {
                    statusText = "Нет сети — переподключусь автоматически"
                } else {
                    statusText = "Нет связи с Telegram, повтор через \(Int(retryDelay)) с…"
                }
                // Exponential backoff; a network change interrupts the wait through reconnect().
                let delay = retryDelay
                retryDelay = min(retryDelay * 2, 30)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    // MARK: - Updates

    private func handle(_ update: TGUpdate) async {
        lastActivity = Date()
        if let callback = update.callbackQuery {
            await handleCallback(callback)
        } else if let message = update.message {
            if let date = message.date, Date(timeIntervalSince1970: TimeInterval(date)) < startedAt.addingTimeInterval(-60) {
                return
            }
            if let webAppData = message.webAppData {
                await handleWebAppData(webAppData.data, message: message)
            } else if let text = message.text {
                await handleText(text, message: message)
            }
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
            case "/start":
                pendingArguments[chatID] = nil
                await sendKeyboard(chatID: chatID)
                await sendMenu(chatID: chatID)
            case "/scripts", "/list", "/menu":
                pendingArguments[chatID] = nil
                await sendMenu(chatID: chatID)
            case "/keyboard":
                await sendKeyboard(chatID: chatID)
            case "/run":
                let rest = String(trimmed.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
                if let match = matchKeyboardLabel(rest) ?? matchKeyboardLabel(Self.labelPrefix + rest) {
                    pendingArguments[chatID] = nil
                    await runScript(match.scriptID, chatID: chatID, arguments: match.arguments)
                } else {
                    await send(chatID, "Скрипт не найден. Формат: <code>/run имя аргументы</code>")
                }
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

        // A pressed reply-keyboard button (possibly sent while the Mac was asleep).
        if let match = matchKeyboardLabel(trimmed) {
            pendingArguments[chatID] = nil
            await runScript(match.scriptID, chatID: chatID, arguments: match.arguments)
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

    /// Commands from the Mini App. They may have waited in Telegram while the Mac was asleep.
    private func handleWebAppData(_ raw: String, message: TGMessage) async {
        guard message.chat.type == "private", let user = message.from, isAuthorized(user.id) else { return }
        let chatID = message.chat.id
        guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let action = object["a"] as? String else {
            await send(chatID, "Не удалось разобрать команду из пульта.")
            return
        }
        switch action {
        case "run":
            guard let shortID = object["s"] as? String else { return }
            if script(forShortID: shortID) == nil { library.reload() }
            guard let script = script(forShortID: shortID) else {
                await send(chatID, "Скрипт не найден. Отправьте /keyboard, чтобы обновить пульт.")
                return
            }
            pendingArguments[chatID] = nil
            // No "r" means the arguments saved on the Mac; "-" means none.
            let arguments = (object["r"] as? String).map {
                $0.trimmingCharacters(in: .whitespaces) == "-" ? "" : $0
            }
            await runScript(script.id, chatID: chatID, arguments: arguments)
        case "stop":
            stopRunning(chatID: chatID)
        default:
            await send(chatID, "Неизвестная команда пульта. Обновите его: /keyboard")
        }
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
        await sendKeyboard(chatID: chatID)
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
        let header = "📄 <b>\(escape(script.name))</b>"
        await sendResult(of: script, output: output, header: header, caption: "📄 \(script.name)", chatID: chatID)
    }

    /// Sends the result in the chosen format: text, image(s) or both.
    private func sendResult(of script: ScriptItem, output: String, header: String, caption: String, chatID: Int64) async {
        if outputFormat != .image {
            await send(chatID, outputText(header: header, output: output))
        } else {
            await send(chatID, header)
        }
        await deliverExtras(of: script, output: output, caption: caption, chatID: chatID)
    }

    /// Images (unless the format is text) and the full output as a file when it does not fit.
    private func deliverExtras(of script: ScriptItem, output: String, caption: String, chatID: Int64) async {
        var imagesTruncated = false
        if outputFormat != .text {
            imagesTruncated = await sendOutputImages(output, caption: caption, chatID: chatID)
        }
        if outputFormat != .image || imagesTruncated {
            await sendFullOutputIfNeeded(script, output: output, chatID: chatID)
        }
    }

    /// Returns true when the output was too long and only its end was drawn.
    private func sendOutputImages(_ output: String, caption: String, chatID: Int64) async -> Bool {
        let text = Self.stripANSI(TerminalImageRenderer.resultText(from: output))
        let rendered = TerminalImageRenderer.pngPages(for: text, style: TerminalImageRenderer.appStyle())
        guard !rendered.pages.isEmpty else { return false }
        let fullCaption = rendered.truncated ? caption + " (конец вывода)" : caption
        do {
            if rendered.pages.count == 1 {
                try await sendMultipart("sendPhoto", chatID: chatID, fields: ["caption": fullCaption], files: [
                    MultipartFile(field: "photo", fileName: "output.png", contentType: "image/png", data: rendered.pages[0])
                ])
            } else {
                var media: [[String: String]] = []
                var files: [MultipartFile] = []
                for (index, page) in rendered.pages.enumerated() {
                    var item = ["type": "photo", "media": "attach://page\(index)"]
                    if index == 0 { item["caption"] = fullCaption }
                    media.append(item)
                    files.append(MultipartFile(field: "page\(index)", fileName: "output-\(index + 1).png", contentType: "image/png", data: page))
                }
                let mediaJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: media)) ?? Data("[]".utf8), as: UTF8.self)
                try await sendMultipart("sendMediaGroup", chatID: chatID, fields: ["media": mediaJSON], files: files)
            }
        } catch {
            // Photos have size limits (e.g. a very wide table); fall back to PNG files without compression.
            for (index, page) in rendered.pages.enumerated() {
                try? await sendMultipart("sendDocument", chatID: chatID, fields: ["caption": index == 0 ? fullCaption : ""], files: [
                    MultipartFile(field: "document", fileName: "output-\(index + 1).png", contentType: "image/png", data: page)
                ])
            }
        }
        return rendered.truncated
    }

    // MARK: - Running scripts

    private func runScript(_ scriptID: String, chatID: Int64, arguments: String?) async {
        if library.script(withID: scriptID) == nil { library.reload() }
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
            text: outputFormat == .image ? header : outputText(header: header, output: output),
            keyboard: [[button("🔁 Ещё раз", "r:\(sid)"), button("📜 К скрипту", "s:\(sid)")], [button("📋 Все скрипты", "l")]],
            reliable: true
        )
        if let script = library.script(withID: scriptID) {
            let plainHeader = header.replacingOccurrences(of: "<b>", with: "").replacingOccurrences(of: "</b>", with: "")
            await deliverExtras(of: script, output: output, caption: Self.unescape(plainHeader), chatID: run.chatID)
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
        clean = Self.compactTables(clean).trimmingCharacters(in: .newlines)
        for budget in stride(from: Self.maxShownCharacters, through: 300, by: -500) {
            let tail = clean.count > budget ? "…\n" + String(clean.suffix(budget)) : clean
            let body = escape(tail.isEmpty ? "(вывода пока нет)" : tail)
            if header.utf16.count + body.utf16.count <= 4_000 { return "\(header)\n<pre>\(body)</pre>" }
        }
        return "\(header)\n<pre>…</pre>"
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Tables

    private static let tableSeparator = try? NSRegularExpression(pattern: "^\\s*-{3,}(\\s+-{3,})+\\s*$")

    private static func isTableSeparator(_ line: String) -> Bool {
        guard let tableSeparator else { return false }
        return tableSeparator.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Fixed-width tables (a header and a "----- -----" line) wrap badly on a phone. Every row becomes
    /// two short lines: the first column, then the other columns joined with " · ".
    /// Only the Telegram view changes; the Mac app and the full-output file keep the original text.
    private static func compactTables(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if index + 1 < lines.count, isTableSeparator(lines[index + 1]),
               !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let columns = columnStarts(lines[index + 1])
                result += compactRow(tableCells(line, columns: columns))
                result.append("")
                var rowIndex = index + 2
                while rowIndex < lines.count {
                    let row = lines[rowIndex]
                    if row.trimmingCharacters(in: .whitespaces).isEmpty || isTableSeparator(row) || row.hasPrefix("[") {
                        break
                    }
                    result += compactRow(tableCells(row, columns: columns))
                    rowIndex += 1
                }
                index = rowIndex
                continue
            }
            result.append(line)
            index += 1
        }
        return result.joined(separator: "\n")
    }

    private static func compactRow(_ cells: [String]) -> [String] {
        let values = cells.map { $0.isEmpty ? "–" : $0 }
        guard let first = values.first else { return [] }
        let rest = values.dropFirst()
        return rest.isEmpty ? [first] : [first, "  " + rest.joined(separator: " · ")]
    }

    private static func columnStarts(_ separator: String) -> [Int] {
        var starts: [Int] = []
        var previous: Character = " "
        for (offset, character) in separator.enumerated() {
            if character == "-" && previous != "-" { starts.append(offset) }
            previous = character
        }
        return starts
    }

    /// Splits a row into cells by column positions; a value wider than its column shifts the rest of the row.
    private static func tableCells(_ line: String, columns: [Int]) -> [String] {
        var cells = Array(repeating: [String](), count: columns.count)
        var shift = 0
        var tokenStart: Int?
        var token = ""
        func flush(end: Int) {
            guard let start = tokenStart else { return }
            var column = 0
            for (k, position) in columns.enumerated() where position <= start - shift { column = k }
            cells[column].append(token)
            if column + 1 < columns.count, end - shift > columns[column + 1] - 1 {
                shift = end - (columns[column + 1] - 1)
            }
            tokenStart = nil
            token = ""
        }
        for (offset, character) in line.enumerated() {
            if character.isWhitespace {
                flush(end: offset)
            } else {
                if tokenStart == nil { tokenStart = offset }
                token.append(character)
            }
        }
        flush(end: line.count)
        return cells.map { $0.joined(separator: " ") }
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
    «📱 Пульт» внизу чата — список скриптов с группами и аргументами. Работает, даже когда Mac спит: скрипт запустится, как только Mac проснётся.
    /run имя аргументы — запуск с аргументами
    /scripts — подробный список с группами, аргументами и последним выводом
    /keyboard — показать пульт заново
    Вывод обновляется в сообщении в реальном времени.
    Пока скрипт работает, любое обычное сообщение отправляется ему в stdin.
    /status — что сейчас выполняется
    /stop — остановить скрипт
    /logout — отключить этот аккаунт
    """

    // MARK: - Reply keyboard (works while the Mac sleeps)

    private struct KeyboardEntry {
        let label: String
        let scriptID: String
    }

    private static let labelPrefix = "▶️ "

    /// Current scripts in the Mac app's order: groups first, then ungrouped. Labels are unique.
    private func currentKeyboardEntries() -> [KeyboardEntry] {
        var ordered: [ScriptItem] = []
        for group in library.groups { ordered += library.scripts(in: group) }
        ordered += library.ungroupedScripts
        let nameCounts = Dictionary(ordered.map { ($0.name, 1) }, uniquingKeysWith: +)
        var used = Set<String>()
        var entries: [KeyboardEntry] = []
        for script in ordered.prefix(150) {
            var label = Self.labelPrefix + String(script.name.prefix(50))
            if (nameCounts[script.name] ?? 0) > 1 { label += " (\(script.folderName))" }
            var unique = label
            var counter = 2
            while used.contains(unique) {
                unique = "\(label) \(counter)"
                counter += 1
            }
            used.insert(unique)
            entries.append(KeyboardEntry(label: unique, scriptID: script.id))
        }
        return entries
    }

    private func catalogChanged() {
        let entries = currentKeyboardEntries()
        // Old labels stay resolvable (a button pressed before a rename still works) unless reused.
        var labels = keyboardLabels
        for entry in entries { labels[entry.label] = entry.scriptID }
        if labels.count > 500 {
            let current = Set(entries.map { $0.label })
            labels = labels.filter { current.contains($0.key) }
        }
        if labels != keyboardLabels {
            keyboardLabels = labels
            defaults.set(labels, forKey: Keys.labels)
        }
        let signature = keyboardSignature(entries)
        if signature != defaults.string(forKey: Keys.keyboardSignature) {
            keyboardDirty = true
            Task { await pushKeyboardIfNeeded() }
        }
    }

    /// Sends the updated keyboard to every authorized chat once the bot is online.
    private func pushKeyboardIfNeeded() async {
        guard keyboardDirty, !isPushingKeyboard, botUsername != nil, activeToken != nil else { return }
        isPushingKeyboard = true
        defer { isPushingKeyboard = false }
        let signature = keyboardSignature(currentKeyboardEntries())
        for user in authorizedUsers {
            await sendKeyboard(chatID: user.id, text: "📱 Пульт", silently: true)
        }
        defaults.set(signature, forKey: Keys.keyboardSignature)
        // The list may have changed again while sending.
        keyboardDirty = keyboardSignature(currentKeyboardEntries()) != signature
    }

    private func keyboardSignature(_ entries: [KeyboardEntry]) -> String {
        // Labels are kept only for /run; the keyboard itself shows just the Mini App button.
        "miniapp:" + (miniAppLaunchURL() ?? "")
    }

    // MARK: - Mini App

    /// Mini App address with the script catalog embedded, so the app works without contacting the Mac.
    private func miniAppLaunchURL() -> String? {
        guard !miniAppURL.isEmpty, var components = URLComponents(string: miniAppURL) else { return nil }
        guard let encoded = encodedCatalog() else { return miniAppURL }
        var items = (components.queryItems ?? []).filter { $0.name != "d" }
        items.append(URLQueryItem(name: "d", value: encoded))
        components.queryItems = items
        return components.string
    }

    /// "j" + base64url(JSON) or "z" + base64url(raw DEFLATE), whichever fits the URL budget first.
    private func encodedCatalog() -> String? {
        let attempts: [(notes: Bool, limit: Int)] = [(true, 500), (false, 500), (false, 120), (false, 60), (false, 30)]
        for attempt in attempts {
            guard let json = catalogPayload(includeNotes: attempt.notes, maxScripts: attempt.limit) else { return nil }
            let plain = "j" + Self.base64URL(json)
            if plain.count <= 3_500 { return plain }
            if let compressed = try? (json as NSData).compressed(using: .zlib) {
                let packed = "z" + Self.base64URL(compressed as Data)
                if packed.count <= 3_500 { return packed }
            }
        }
        return nil
    }

    private func catalogPayload(includeNotes: Bool, maxScripts: Int) -> Data? {
        let scripts = Array(library.scripts.prefix(maxScripts))
        var indexByID: [String: Int] = [:]
        var items: [[String]] = []
        for script in scripts {
            indexByID[script.id] = items.count
            let note = includeNotes ? String(library.note(for: script).prefix(200)) : ""
            items.append([script.name, note, Self.shortID(script.id)])
        }
        var groups: [[Any]] = []
        for group in library.groups {
            let indices: [Int] = library.scripts(in: group).compactMap { indexByID[$0.id] }
            groups.append([group.name, indices])
        }
        let payload: [String: Any] = [
            "v": 1,
            "h": hostName,
            "s": items,
            "g": groups,
            "t": scripts.count < library.scripts.count
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The chat keyboard holds a single "📱 Пульт" button that opens the Mini App.
    /// Without a Mini App address the keyboard is removed.
    /// `silently`: the keyboard is updated without leaving a message in the chat. Telegram only changes
    /// the keyboard together with a message, so it is sent without a sound and deleted right away.
    private func sendKeyboard(chatID: Int64, text: String? = nil, silently: Bool = false) async {
        let markup: [String: Any]
        let message: String
        if let launchURL = miniAppLaunchURL() {
            markup = [
                "keyboard": [[["text": "📱 Пульт", "web_app": ["url": launchURL]]]],
                "resize_keyboard": true,
                "is_persistent": true,
                "input_field_placeholder": "Аргументы или ответ скрипту"
            ]
            message = text ?? "📱 Пульт внизу чата открывает список скриптов. Он работает, даже когда Mac спит: "
                + "скрипт запустится сразу после пробуждения."
        } else {
            markup = ["remove_keyboard": true]
            message = "Пульт не настроен: укажите адрес Mini App в MacScriptRunner → Settings → Telegram-бот. "
                + "Пока запускайте скрипты через /scripts или /run имя."
        }
        if silently {
            guard let sent = try? await sendMessage(chatID, message, replyMarkup: markup, silent: true) else { return }
            let _: TGIgnored? = try? await call("deleteMessage", ["chat_id": chatID, "message_id": sent.messageId])
        } else {
            _ = try? await sendMessage(chatID, message, replyMarkup: markup)
        }
    }

    /// Resolves "▶️ name" or "▶️ name arguments" to a script using the cached labels.
    private func matchKeyboardLabel(_ text: String) -> (scriptID: String, arguments: String?)? {
        guard text.hasPrefix(Self.labelPrefix) || keyboardLabels[text] != nil else { return nil }
        if let scriptID = keyboardLabels[text] { return (scriptID, nil) }
        // Longest label first so "▶️ deploy prod" prefers a script named "deploy prod" over "deploy".
        for label in keyboardLabels.keys.sorted(by: { $0.count > $1.count }) where text.hasPrefix(label + " ") {
            let arguments = String(text.dropFirst(label.count + 1)).trimmingCharacters(in: .whitespaces)
            return (keyboardLabels[label] ?? "", arguments)
        }
        return nil
    }

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
        try await sendMessage(chatID, text, replyMarkup: keyboard.map { ["inline_keyboard": $0] })
    }

    private func sendMessage(
        _ chatID: Int64,
        _ text: String,
        replyMarkup: [String: Any]?,
        silent: Bool = false
    ) async throws -> TGMessage {
        var parameters: [String: Any] = [
            "chat_id": chatID,
            "text": text,
            "parse_mode": "HTML",
            "disable_web_page_preview": true
        ]
        if silent { parameters["disable_notification"] = true }
        if let replyMarkup { parameters["reply_markup"] = replyMarkup }
        return try await reliably { () async throws -> TGMessage in
            try await self.call("sendMessage", parameters)
        }
    }

    /// `reliable`: retried through network outages (final results); progress updates are not.
    private func edit(chatID: Int64, messageID: Int, text: String, keyboard: Keyboard?, reliable: Bool = false) async {
        var parameters: [String: Any] = [
            "chat_id": chatID,
            "message_id": messageID,
            "text": text,
            "parse_mode": "HTML",
            "disable_web_page_preview": true
        ]
        if let keyboard { parameters["reply_markup"] = ["inline_keyboard": keyboard] }
        // "message is not modified" and similar errors are harmless here.
        if reliable {
            _ = try? await reliably { () async throws -> TGIgnored in
                try await self.call("editMessageText", parameters)
            }
        } else {
            let _: TGIgnored? = try? await call("editMessageText", parameters)
        }
    }

    private func answer(_ callback: TGCallbackQuery, text: String? = nil) async {
        var parameters: [String: Any] = ["callback_query_id": callback.id]
        if let text { parameters["text"] = text }
        let _: TGIgnored? = try? await call("answerCallbackQuery", parameters)
    }

    private struct MultipartFile {
        let field: String
        let fileName: String
        let contentType: String
        let data: Data
    }

    private func sendDocument(chatID: Int64, fileName: String, data: Data, caption: String) async throws {
        try await sendMultipart("sendDocument", chatID: chatID, fields: ["caption": caption], files: [
            MultipartFile(field: "document", fileName: fileName, contentType: "text/plain; charset=utf-8", data: data)
        ])
    }

    private func sendMultipart(_ method: String, chatID: Int64, fields: [String: String], files: [MultipartFile]) async throws {
        guard let activeToken, let url = URL(string: "https://api.telegram.org/bot\(activeToken)/\(method)") else { return }
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        appendField("chat_id", String(chatID))
        for (name, value) in fields where !value.isEmpty { appendField(name, value) }
        for file in files {
            let safeName = file.fileName.replacingOccurrences(of: "\"", with: "'")
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(safeName)\"\r\nContent-Type: \(file.contentType)\r\n\r\n".utf8))
            body.append(file.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let _: TGIgnored = try await reliably { () async throws -> TGIgnored in
            try await self.perform(request)
        }
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
