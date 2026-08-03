import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: ScriptLibrary
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue

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
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 540, height: 260)
    }
}
