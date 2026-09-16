import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: ScriptLibrary
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    @AppStorage("terminalFontSize") private var terminalFontSize = 13.0
    @AppStorage("terminalLineWrapping") private var terminalLineWrapping = true
    @AppStorage("groupLongScriptLists") private var groupLongScriptLists = true
    @AppStorage("scriptGroupingThreshold") private var scriptGroupingThreshold = 12

    var body: some View {
        Form {
            Section("Папка со скриптами") {
                HStack {
                    Text(model.folderPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Выбрать…") { model.chooseFolder() }
                }
                Text("В список добавляются файлы с расширением .sh. Изменения появятся после возврата в приложение или обновления списка.")
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

            Section("Список скриптов") {
                Toggle("Группировать длинный список", isOn: $groupLongScriptLists)
                Stepper(value: $scriptGroupingThreshold, in: 5...50) {
                    HStack {
                        Text("Группировать, если скриптов больше")
                        Spacer()
                        Text("\(scriptGroupingThreshold)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!groupLongScriptLists)
                Text("Скрипты автоматически распределяются по сворачиваемым секциям по первой букве имени. Состояние секций сохраняется.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .frame(width: 560, height: 520)
    }
}
