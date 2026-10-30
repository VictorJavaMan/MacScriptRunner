import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: ScriptLibrary
    @EnvironmentObject private var telegram: TelegramBot
    @EnvironmentObject private var power: PowerManager
    @State private var telegramTokenDraft = ""
    @State private var miniAppURLDraft = ""
    @State private var miniAppError: String?
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @AppStorage("terminalFontSize") private var terminalFontSize = 13.0
    @AppStorage("terminalLineWrapping") private var terminalLineWrapping = true

    var body: some View {
        Form {
            Section("Папки со скриптами") {
                if model.folderURLs.isEmpty {
                    Text("Папки не добавлены")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.folderURLs, id: \.path) { folder in
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(folder.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(role: .destructive) {
                                model.removeFolder(folder)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Удалить папку из списка")
                        }
                    }
                }
                Button {
                    model.chooseFolder()
                } label: {
                    Label("Добавить папки…", systemImage: "folder.badge.plus")
                }
                Text("Можно выбрать сразу несколько папок. В общий список добавляются файлы с расширением .sh; сами папки и файлы не изменяются.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Telegram-бот") {
                Toggle("Управлять скриптами через Telegram", isOn: $telegram.isEnabled)
                LabeledContent("Статус") {
                    Text(telegram.statusText)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    SecureField(
                        telegram.hasToken ? "Токен сохранён — введите новый, чтобы заменить" : "Токен от @BotFather",
                        text: $telegramTokenDraft
                    )
                    Button("Сохранить") {
                        telegram.saveToken(telegramTokenDraft)
                        telegramTokenDraft = ""
                    }
                    .disabled(telegramTokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    TextField("Адрес Mini App (https://…/index.html), необязательно", text: $miniAppURLDraft)
                        .onAppear { miniAppURLDraft = telegram.miniAppURL }
                    Button("Сохранить") {
                        miniAppError = telegram.setMiniAppURL(miniAppURLDraft)
                    }
                    .disabled(miniAppURLDraft == telegram.miniAppURL)
                }
                if let miniAppError {
                    Text(miniAppError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Picker("Результат скрипта", selection: $telegram.outputFormat) {
                    ForEach(TelegramOutputFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                LabeledContent("Код доступа") {
                    HStack(spacing: 8) {
                        Text(telegram.formattedAccessCode)
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                        Button {
                            telegram.regenerateAccessCode()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Сгенерировать новый код")
                    }
                }
                if telegram.authorizedUsers.isEmpty {
                    Text("Пока никто не подключён")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(telegram.authorizedUsers) { user in
                        HStack {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(.secondary)
                            Text(user.name)
                            Spacer()
                            Button(role: .destructive) {
                                telegram.removeUser(user)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Отозвать доступ")
                        }
                    }
                }
                Text("1. Создайте бота у @BotFather в Telegram и вставьте сюда его токен.\n2. Откройте бота и отправьте ему код доступа.\nБот работает из любой сети, пока Mac включён, не спит и приложение запущено. При смене кода уже подключённые аккаунты сохраняют доступ — отзывайте его в списке выше.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Работа в фоне") {
                Toggle("Запускать MacScriptRunner при входе в систему", isOn: Binding(
                    get: { power.launchAtLogin },
                    set: { power.setLaunchAtLogin($0) }
                ))
                Toggle("Не засыпать при бездействии, пока бот включён", isOn: $telegram.keepAwake)
                Toggle("Умный режим питания (со сном на батарее)", isOn: Binding(
                    get: { power.isGuardInstalled },
                    set: { power.setGuardInstalled($0) }
                ))
                .disabled(power.isWorking)
                Picker("На батарее просыпаться", selection: $power.wakeIntervalMinutes) {
                    ForEach(PowerManager.wakeIntervalChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "никогда" : "каждые \(minutes) мин").tag(minutes)
                    }
                }
                .disabled(!power.isGuardInstalled)
                LabeledContent("Питание") {
                    Text(power.powerSummary)
                        .foregroundStyle(.secondary)
                }
                if let message = power.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("Во сне macOS замораживает все сторонние приложения. Умный режим устанавливает системную службу (спросит пароль администратора): от сети Mac не засыпает даже с закрытой крышкой и бот отвечает сразу; от батареи Mac спит, но просыпается по расписанию, бот выполняет накопившиеся команды и Mac снова засыпает. Пока выполняется скрипт, Mac не уснёт (если заряд выше 10%). Выключение переключателя удаляет службу и возвращает обычный сон.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Оформление") {
                Picker("Тема", selection: $appearance) {
                    ForEach(Appearance.allCases) { theme in
                        Text(theme.title).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Терминал") {
                HStack {
                    Text("Масштаб текста")
                    Slider(value: $terminalFontSize, in: 10...24, step: 1)
                    Text("\(Int(terminalFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                    Button("Сбросить") { terminalFontSize = 13 }
                        .disabled(terminalFontSize == 13)
                }
                Text("Размер применяется к выводу и строке ввода и сохраняется после перезапуска приложения.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Переносить длинные строки", isOn: $terminalLineWrapping)
                Text(terminalLineWrapping
                     ? "Длинные строки подстраиваются под ширину терминала."
                     : "Длинные строки не переносятся; доступна горизонтальная прокрутка.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 620, height: 720)
        .onAppear { power.refresh() }
    }
}
