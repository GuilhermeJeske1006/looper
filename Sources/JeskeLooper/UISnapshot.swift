import AppKit
import AVFoundation
import LooperCore
import SwiftUI

/// Validation aid: renders the windows offscreen to PNG files, using a temporary loop folder,
/// temporary preferences and silent playback. Run with JESKE_SNAPSHOT_DIR=<folder>.
@MainActor
enum UISnapshot {
    static func run(into output: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("JeskeLooperSnapshot-\(UUID().uuidString)", isDirectory: true)
        let suite = "com.guilhermejeske.JeskeLooper.snapshot"
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? fm.createDirectory(at: output, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: folder)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        for (name, seconds, pitch) in [("Base do refrão", 4.0, 220.0), ("Groove", 2.5, 330.0), ("Ponte", 3.2, 262.0)] {
            writeTone(folder.appendingPathComponent("\(name).wav"), seconds: seconds, pitch: pitch)
            pump(0.05)
        }
        UserDefaults().removePersistentDomain(forName: suite)
        let model = LooperController(store: LoopStore(directory: folder), defaults: UserDefaults(suiteName: suite)!)
        model.setVolume(0)
        model.start()
        let shortcuts = ShortcutCenter()
        pump(1.2)
        if let first = model.loops.first { model.play(loopID: first.id) }
        pump(1.6)
        if model.loops.count > 1 { model.play(loopID: model.loops[1].id) }
        pump(0.4)

        for (suffix, appearance) in [("escuro", NSAppearance.Name.darkAqua), ("claro", .aqua)] {
            render(ContentView().environmentObject(model).environmentObject(shortcuts),
                   size: NSSize(width: 460, height: 740), appearance: appearance,
                   to: output.appendingPathComponent("janela-\(suffix).png"))
        }
        render(KeyboardSettings().environmentObject(shortcuts),
               size: NSSize(width: 520, height: 560), appearance: .darkAqua, to: output.appendingPathComponent("ajustes-teclado.png"))
        render(LoopSettings().environmentObject(model),
               size: NSSize(width: 520, height: 400), appearance: .darkAqua, to: output.appendingPathComponent("ajustes-loops.png"))
        render(HelpView().background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 380, height: 560),
               appearance: .darkAqua, to: output.appendingPathComponent("ajuda.png"))
        checkKeyRouting(model: model, shortcuts: shortcuts)
        model.shutdown()
        pump(0.3)
    }

    /// Sends real key events through the same routing the window uses and prints the outcome.
    private static func checkKeyRouting(model: LooperController, shortcuts: ShortcutCenter) {
        shortcuts.settings = .standard
        shortcuts.attach(model)
        var failures = 0
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], repeated: Bool = false) -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                               windowNumber: 0, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: repeated, keyCode: code) else { return false }
            return shortcuts.route(event)
        }
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "PASS" : "FAIL")  \(name)")
            if !ok { failures += 1 }
        }
        guard model.loops.count >= 3 else { print("  FAIL  loops de exemplo"); return }
        let ids = model.loops.map(\.id)
        print("▸ Teclas (eventos reais de teclado)")
        model.stopPlayback()
        pump(0.3)
        check("Tecla 1 repete o loop 1", key(18, "1") && model.playingLoopID == ids[0])
        pump(0.5)
        check("Tecla 2 põe o loop 2 como Próximo", key(19, "2") && model.queuedLoopID == ids[1] && model.playingLoopID == ids[0])
        check("Tecla 1 (loop atual) cancela o Próximo", key(18, "1") && model.queuedLoopID == nil && model.playingLoopID == ids[0])
        check("Tecla 2 duas vezes troca na hora", key(19, "2") && key(19, "2") && model.playingLoopID == ids[1] && model.queuedLoopID == nil)
        check("⇧3 troca na hora para o loop 3", key(20, "#", .shift) && model.playingLoopID == ids[2])
        check("Teclado numérico 1 põe o loop 1 como Próximo", key(83, "1", .numericPad) && model.queuedLoopID == ids[0])
        check("Esc para a repetição e limpa a fila", key(53, "\u{1b}") && !model.isPlaying && model.queuedLoopID == nil)
        model.selectedLoopID = ids[0]
        check("↓ seleciona o próximo loop", key(125, "\u{F701}", [.function, .numericPad]) && model.selectedLoopID == ids[1])
        check("↓ segurado continua descendo", key(125, "\u{F701}", [.function, .numericPad], repeated: true) && model.selectedLoopID == ids[2])
        check("↩ repete o selecionado", key(36, "\r") && model.playingLoopID == ids[2])
        check("⌘ + tecla fica para os menus", !key(18, "1", .command) && model.playingLoopID == ids[2])
        check("Tecla sem atalho não é capturada", !key(0, "a"))
        check("Tecla 1 segurada não repete a ação", key(18, "1", repeated: true) && model.queuedLoopID == nil)
        model.stopPlayback()
        pump(0.3)
        let canRecord = model.canRecord
        check("Espaço começa a gravar", key(49, " ") && (model.isRecording || !canRecord))
        pump(0.6)
        check("Espaço de novo para a gravação", key(49, " ") && !model.isRecording)
        pump(1.5)
        let probe = shortcuts.probeGlobalHotKeys()
        check("Atalhos globais ⌃⌥ registrados (\(probe.registered))" + (probe.failures.isEmpty ? "" : " — já usados: \(probe.failures.joined(separator: ", "))"),
              probe.registered > 0)
        print("Teclas: \(failures == 0 ? "todas passaram" : "\(failures) falharam")")
    }

    private static func pump(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        pump(0.6)
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func writeTone(_ url: URL, seconds: Double, pitch: Double) {
        let rate = 44_100.0
        guard let format = LoopAudioFormat.processingFormat(sampleRate: rate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate)),
              let writer = try? LoopFileWriter(url: url, format: format) else { return }
        buffer.frameLength = buffer.frameCapacity
        for c in 0..<2 {
            for i in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![c][i] = Float(0.3 * sin(2 * .pi * pitch * Double(i) / rate))
            }
        }
        writer.append(buffer)
        writer.close()
    }
}
