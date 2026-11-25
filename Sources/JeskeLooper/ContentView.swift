import AppKit
import LooperCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: LooperController
    @State private var showHelp = false
    @State private var renameTarget: LoopItem?
    @State private var renameText = ""
    @State private var deleteTarget: LoopItem?

    var body: some View {
        VStack(spacing: 12) {
            header
            DevicesPanel()
            RecordPanel()
            if let banner = model.banner {
                BannerView(banner: banner)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            LoopsPanel(onRename: { item in
                renameText = item.name
                renameTarget = item
            }, onDelete: { item in
                deleteTarget = item
            })
            PlaybackBar()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .frame(width: 460, height: 740)
        .background(Theme.background)
        .animation(.easeOut(duration: 0.2), value: model.banner)
        .alert("Renomear loop",
               isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }),
               presenting: renameTarget) { item in
            TextField("Nome do loop", text: $renameText)
            Button("Salvar") { model.rename(loopID: item.id, to: renameText) }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in
            Text("O arquivo de áudio é renomeado junto.")
        }
        .confirmationDialog(deleteTarget.map { "Excluir “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            presenting: deleteTarget) { item in
            Button("Excluir", role: .destructive) { model.delete(loopID: item.id) }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in
            Text("O arquivo de áudio vai para o Lixo.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showLooperHelp)) { _ in showHelp = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("Jeske Looper").font(.system(size: 17, weight: .bold))
                Text("Grave o teclado e deixe repetindo").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill()
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 16))
            }
            .buttonStyle(.borderless)
            .help("Ajustes e teclas de atalho (⌘,)")
            Button { showHelp.toggle() } label: {
                Image(systemName: "questionmark.circle").font(.system(size: 17))
            }
            .buttonStyle(.borderless)
            .help("Ajuda")
            .popover(isPresented: $showHelp, arrowEdge: .bottom) { HelpView() }
        }
        .padding(.top, 18)
    }
}

// MARK: - Status

struct StatusPill: View {
    @EnvironmentObject private var model: LooperController

    var body: some View {
        let (text, color) = describe()
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.14)))
    }

    private func describe() -> (String, Color) {
        switch model.mode {
        case .idle: return ("Parado", .secondary)
        case .recording: return ("Gravando", Theme.record)
        case .saving: return ("Salvando…", .orange)
        case .playing: return ("Repetindo", Theme.play)
        }
    }
}

struct BannerView: View {
    @EnvironmentObject private var model: LooperController
    let banner: Banner

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text(banner.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                if banner.action == .openMicrophoneSettings {
                    Button("Abrir Ajustes do Sistema") { NSWorkspace.shared.open(MicrophonePermission.settingsURL) }
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            Button { model.banner = nil } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Fechar")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.3)))
        .task(id: banner.id) {
            guard banner.kind == .info else { return }
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if model.banner?.id == banner.id { model.banner = nil }
        }
    }

    private var icon: String {
        switch banner.kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch banner.kind {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Devices

struct DevicesPanel: View {
    @EnvironmentObject private var model: LooperController

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                DevicePicker(title: "Entrada de áudio",
                             icon: "pianokeys",
                             devices: model.inputDevices,
                             saved: model.savedInput,
                             status: model.inputStatus,
                             onSelect: { model.selectInput(uid: $0) })
                LevelMeterView(level: model.level, active: model.inputIsReady)
                Divider().padding(.vertical, 2)
                DevicePicker(title: "Saída de áudio",
                             icon: "speaker.wave.2",
                             devices: model.outputDevices,
                             saved: model.savedOutput,
                             status: model.outputStatus,
                             onSelect: { model.selectOutput(uid: $0) })
            }
            .disabled(!model.canChangeDevices)
        }
    }
}

struct DevicePicker: View {
    let title: String
    let icon: String
    let devices: [AudioDevice]
    let saved: SavedDevice?
    let status: DeviceStatus
    let onSelect: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(title, selection: Binding(get: { saved?.uid ?? "" }, set: { onSelect($0.isEmpty ? nil : $0) })) {
                Text("Nenhum").tag("")
                if let saved, !devices.contains(where: { $0.uid == saved.uid }) {
                    Text("\(saved.name) (desconectado)").tag(saved.uid)
                }
                ForEach(devices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            statusLine
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch status {
        case .notSelected:
            StatusText(text: "Escolha um dispositivo", color: .secondary)
        case .starting:
            StatusText(text: "Preparando…", color: .secondary)
        case .ready(let detail):
            StatusText(text: "Pronto · \(detail)", color: Theme.play)
        case .disconnected:
            StatusText(text: "Desconectado — reconecte o dispositivo ou escolha outro", color: .orange)
        case .permissionNeeded:
            StatusText(text: "Sem permissão de acesso à entrada de áudio", color: .orange)
        case .problem(let message):
            StatusText(text: message, color: .red)
        }
    }
}

private struct StatusText: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption).foregroundStyle(color == .secondary ? Color.secondary : color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Recording

struct RecordPanel: View {
    @EnvironmentObject private var model: LooperController
    @EnvironmentObject private var shortcuts: ShortcutCenter

    var body: some View {
        HStack(spacing: 10) {
            Button { model.startRecording() } label: { recordLabel }
                .buttonStyle(BigButtonStyle(color: Theme.record, filled: true, active: model.isBusy, height: 58))
                .disabled(!model.canRecord)
                .keyboardShortcut("r", modifiers: .command)
                .help("Gravar o áudio da entrada (\(shortcuts.label(for: .toggleRecording) ?? "⌘R"))")

            Button { model.stopRecording() } label: {
                VStack(spacing: 3) {
                    Label("Parar gravação", systemImage: "stop.fill")
                    if let key = shortcuts.label(for: .toggleRecording) { Keycap(text: key, tint: Theme.record) }
                }
            }
            .buttonStyle(BigButtonStyle(color: Theme.record, filled: false, height: 58))
            .frame(width: 168)
            .disabled(!model.isRecording)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Parar, salvar e começar a repetir (⌘↩)")
        }
    }

    @ViewBuilder private var recordLabel: some View {
        switch model.mode {
        case .recording(let since):
            HStack(spacing: 9) {
                PulsingDot()
                TimelineView(.periodic(from: since, by: 0.1)) { context in
                    Text("Gravando  \(LooperFormat.duration(context.date.timeIntervalSince(since)))")
                        .monospacedDigit()
                }
            }
        case .saving:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Salvando…")
            }
        default:
            HStack(spacing: 9) {
                Circle().fill(.white).frame(width: 14, height: 14)
                Text("Gravar").font(.system(size: 18, weight: .bold))
                if let key = shortcuts.label(for: .toggleRecording) { Keycap(text: key, tint: .white) }
            }
        }
    }
}

struct PulsingDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 12, height: 12)
            .opacity(on ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

// MARK: - Loops

struct LoopsPanel: View {
    @EnvironmentObject private var model: LooperController
    @StateObject private var progress = CycleProgress()
    let onRename: (LoopItem) -> Void
    let onDelete: (LoopItem) -> Void

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Loops salvos").font(.headline)
                    if !model.loops.isEmpty {
                        Text("\(model.loops.count)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    Spacer()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([model.store.directory])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Mostrar a pasta dos loops no Finder")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
                if model.loops.isEmpty {
                    emptyState
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(Array(model.loops.enumerated()), id: \.element.id) { index, item in
                                    LoopRow(item: item, number: index + 1, progress: progress,
                                            onRename: onRename, onDelete: onDelete)
                                        .id(item.id)
                                }
                            }
                            .padding(8)
                        }
                        .onChange(of: model.selectedLoopID) { _, id in
                            guard let id else { return }
                            withAnimation { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity)
        .onAppear { progress.start(model.player) }
        .onDisappear { progress.stop() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(Theme.brand.opacity(0.7))
            Text("Nenhum loop ainda").font(.callout.weight(.semibold))
            Text("Clique em Gravar, toque no CK61 e depois em Parar gravação.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

struct LoopRow: View {
    @EnvironmentObject private var model: LooperController
    @EnvironmentObject private var shortcuts: ShortcutCenter
    let item: LoopItem
    let number: Int
    @ObservedObject var progress: CycleProgress
    let onRename: (LoopItem) -> Void
    let onDelete: (LoopItem) -> Void

    private var isPlaying: Bool { model.playingLoopID == item.id }
    private var isQueued: Bool { model.queuedLoopID == item.id }
    private var isProcessing: Bool { model.processingLoopID == item.id }
    private var isSelected: Bool { model.selectedLoopID == item.id }

    var body: some View {
        HStack(spacing: 10) {
            if shortcuts.settings.numberKeysPlayLoops && number <= 9 {
                Keycap(text: "\(number)", tint: isPlaying ? Theme.play : .secondary)
                    .help("Tecla \(number): repetir este loop")
            }
            ZStack {
                Circle().fill((isPlaying ? Theme.play : Theme.brand).opacity(0.15)).frame(width: 30, height: 30)
                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.play)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(LooperFormat.duration(item.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if isQueued {
                        Text("Próximo")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.brand))
                            .help("Começa quando a volta atual terminar")
                    }
                }
                if isPlaying { CycleProgressBar(progress: progress) }
            }
            Spacer(minLength: 6)
            if isProcessing {
                ProgressView().controlSize(.small).padding(.horizontal, 8)
            } else if isPlaying {
                Text("Repetindo")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.play)
                    .padding(.horizontal, 8)
            } else {
                Button {
                    model.play(loopID: item.id)
                } label: {
                    Label(isQueued ? "Trocar já" : "Repetir", systemImage: isQueued ? "forward.end.fill" : "repeat")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
                .controlSize(.regular)
                .disabled(!model.canPlay)
                .help(isQueued ? "Trocar agora, sem esperar o fim da volta" : "Repetir este loop (⇧ troca na hora)")
            }
            Menu {
                Button("Renomear…") { onRename(item) }
                Button("Cortar silêncio das bordas") { model.trimSilence(loopID: item.id) }
                Divider()
                Button("Excluir…", role: .destructive) { onDelete(item) }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!model.canEditLoops)
            .help("Renomear ou excluir")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isPlaying ? Theme.play.opacity(0.10) : (isSelected ? Theme.brand.opacity(0.10) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isQueued ? Theme.brand.opacity(0.6) : (isSelected && !isPlaying ? Theme.brand.opacity(0.35) : .clear),
                              style: StrokeStyle(lineWidth: 1.2, dash: isQueued ? [4, 3] : []))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectedLoopID = item.id }
        .contextMenu {
            Button("Repetir") { model.play(loopID: item.id) }.disabled(!model.canPlay)
            Button("Renomear…") { onRename(item) }.disabled(!model.canEditLoops)
            Button("Cortar silêncio das bordas") { model.trimSilence(loopID: item.id) }.disabled(!model.canEditLoops)
            Divider()
            Button("Excluir…", role: .destructive) { onDelete(item) }.disabled(!model.canEditLoops)
        }
    }
}

// MARK: - Playback

struct PlaybackBar: View {
    @EnvironmentObject private var model: LooperController
    @EnvironmentObject private var shortcuts: ShortcutCenter

    var body: some View {
        Card(padding: 12) {
            HStack(spacing: 12) {
                Button { model.stopPlayback() } label: {
                    HStack(spacing: 6) {
                        Label("Parar", systemImage: "stop.fill")
                        if let key = shortcuts.label(for: .stopPlayback) { Keycap(text: key) }
                    }
                }
                .buttonStyle(BigButtonStyle(color: .primary, filled: false, height: 40))
                .frame(width: 128)
                .disabled(!model.isPlaying)
                .keyboardShortcut(".", modifiers: .command)
                .help("Parar a repetição (⌘.)")

                Image(systemName: "speaker.fill").foregroundStyle(.secondary).font(.caption)
                Slider(value: Binding(get: { Double(model.volume) }, set: { model.setVolume(Float($0)) }), in: 0...1)
                    .tint(Theme.brand)
                    .help("Volume da reprodução")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).font(.caption)
                Text("\(Int((model.volume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}

// MARK: - Keyboard hints and turn progress

struct Keycap: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .frame(minWidth: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(tint.opacity(0.45)))
    }
}

/// Polls where the playing loop is inside its turn. Only the progress bar observes it.
@MainActor
final class CycleProgress: ObservableObject {
    @Published private(set) var value: Double = 0
    private var timer: Timer?

    func start(_ player: LoopPlayer) {
        stop()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            let position = player.position()
            MainActor.assumeIsolated {
                let next = position?.progress ?? 0
                if abs(next - (self?.value ?? 0)) > 0.002 { self?.value = next }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

struct CycleProgressBar: View {
    @ObservedObject var progress: CycleProgress

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.play.opacity(0.18))
                Capsule().fill(Theme.play).frame(width: max(3, geo.size.width * progress.value))
            }
        }
        .frame(width: 150, height: 3)
        .help("Posição na volta atual")
    }
}
