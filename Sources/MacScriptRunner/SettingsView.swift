import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: ScriptLibrary
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
        .frame(width: 620, height: 480)
    }
}
