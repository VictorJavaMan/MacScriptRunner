import SwiftUI

@main
struct MacScriptRunnerApp: App {
    @StateObject private var model = ScriptLibrary()
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Скрипты") {
                Button("Обновить список") { model.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Остановить выполняемый скрипт") { model.stopRunningScript() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.runningScriptID == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
        }

        WindowGroup("Редактор скрипта", id: "script-editor", for: String.self) { $scriptID in
            ScriptEditorView(scriptID: scriptID ?? "")
                .environmentObject(model)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
        }
        .defaultSize(width: 820, height: 620)
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Системная"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
