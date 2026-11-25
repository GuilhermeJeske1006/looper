import LooperCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var shortcuts: ShortcutCenter

    var body: some View {
        TabView {
            KeyboardSettings()
                .tabItem { Label("Teclado", systemImage: "keyboard") }
            LoopSettings()
                .tabItem { Label("Loops", systemImage: "repeat") }
        }
        .onDisappear { shortcuts.recording = nil }
    }
}

struct KeyboardSettings: View {
    @EnvironmentObject private var shortcuts: ShortcutCenter

    var body: some View {
        Form {
            Section {
                ForEach(LooperCommand.allCases) { command in
                    LabeledContent(command.title) { ShortcutRecorder(command: command) }
                }
                Toggle("Teclas 1 a 9 repetem os loops 1 a 9", isOn: $shortcuts.settings.numberKeysPlayLoops)
                Toggle("Funcionar também com outro app na frente", isOn: $shortcuts.settings.worksInBackground)
                if shortcuts.settings.worksInBackground {
                    Text("Com outro app na frente, use ⌃⌥ + a tecla (por exemplo ⌃⌥Espaço para gravar ou ⌃⌥1 para o loop 1).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !shortcuts.globalProblems.isEmpty {
                        Text("Já usados por outro app: \(shortcuts.globalProblems.joined(separator: ", ")).")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Segure ⇧ junto para trocar de loop na hora. Para mudar uma tecla, clique nela e pressione a nova; ⌫ apaga.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restaurar padrões") { shortcuts.restoreDefaults() }
                }
            } header: {
                Text("Teclado do Mac")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
    }
}

struct LoopSettings: View {
    @EnvironmentObject private var model: LooperController

    var body: some View {
        Form {
            Section("Troca de loop") {
                Picker("Ao escolher outro loop", selection: $model.switchMode) {
                    Text("Esperar o fim da volta atual (sem pausa)").tag(LoopSwitchMode.atCycleEnd)
                    Text("Trocar na hora, com transição suave").tag(LoopSwitchMode.immediate)
                }
                .pickerStyle(.radioGroup)
                Text("Esperando o fim da volta, escolher de novo o loop marcado como “Próximo” troca na hora.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Gravação") {
                Toggle("Cortar o silêncio antes da primeira nota", isOn: $model.trimLeadingSilence)
                Toggle("Cortar o silêncio depois da última nota", isOn: $model.trimTrailingSilence)
                Text("Desligue o segundo se o loop termina com uma pausa proposital.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 400)
    }
}

struct ShortcutRecorder: View {
    @EnvironmentObject private var shortcuts: ShortcutCenter
    let command: LooperCommand

    var body: some View {
        let isRecording = shortcuts.recording == command
        VStack(alignment: .trailing, spacing: 3) {
            Button {
                shortcuts.toggleRecording(command)
            } label: {
                Text(isRecording ? "Pressione uma tecla…" : (shortcuts.label(for: command) ?? "—"))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? Theme.brand : nil)
            .help(isRecording ? "Clique de novo para cancelar" : "Clique e pressione a nova tecla")
            if isRecording, let message = shortcuts.recordingMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
