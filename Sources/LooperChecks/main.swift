// Validation tool for Jeske Looper. Uses the real audio hardware when available.
// Playback checks run at volume 0 (silent); recordings go to a temporary folder and are deleted.
//
//   swift run -c release LooperChecks            # all checks
//   swift run -c release LooperChecks --offline  # only checks that need no audio device

import AVFoundation
import CoreAudio
import Foundation
import LooperCore

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - Reporting

@MainActor
final class Report {
    var passed = 0
    var failed: [String] = []
    var skipped: [String] = []

    func section(_ title: String) { print("\n▸ \(title)") }

    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("  \(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        if ok { passed += 1 } else { failed.append(name) }
    }

    func skip(_ name: String, _ why: String) {
        print("  SKIP  \(name) — \(why)")
        skipped.append("\(name): \(why)")
    }

    func note(_ text: String) { print("        \(text)") }
}

func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@MainActor
func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        await pause(0.02)
    }
    return condition()
}

// MARK: - Audio helpers

func noise(_ channel: Int, _ index: Int, seed: UInt64) -> Float {
    var x = UInt64(index) &* 0x9E37_79B9_7F4A_7C15 ^ (UInt64(channel) &+ seed) &* 0xBF58_476D_1CE4_E5B9
    x ^= x >> 31
    x = x &* 0x94D0_49BB_1331_11EB
    x ^= x >> 29
    return Float(x % 2_000_001) / 2_000_000 * 0.6 - 0.3
}

/// Smooth (music-like) but not periodic over the loop, so the seam has a jump.
func tones(_ channel: Int, _ index: Int, sampleRate: Double) -> Float {
    let t = Float(Double(index) / sampleRate)
    let phase = Float(channel)
    return 0.3 * sin(2 * .pi * 220.7 * t + phase) + 0.2 * sin(2 * .pi * 331.9 * t + 1 + phase) + 0.1 * sin(2 * .pi * 1234.5 * t + 2)
}

func writeLoop(_ url: URL, seconds: Double, sampleRate: Double, channels: AVAudioChannelCount,
               _ signal: (Int, Int) -> Float) throws {
    let format = LoopAudioFormat.processingFormat(sampleRate: sampleRate, channels: channels)!
    let writer = try LoopFileWriter(url: url, format: format)
    let total = Int(seconds * sampleRate)
    var position = 0
    while position < total {
        let n = min(4096, total - position)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        for c in 0..<Int(channels) {
            for i in 0..<n { buffer.floatChannelData![c][i] = signal(c, position + i) }
        }
        writer.append(buffer)
        position += n
    }
    writer.close()
    if let error = writer.error { throw error }
}

func readAll(_ url: URL) throws -> (channels: [[Float]], sampleRate: Double) {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let channels = (0..<Int(file.processingFormat.channelCount)).map { c in
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![c], count: Int(buffer.frameLength)))
    }
    return (channels, file.processingFormat.sampleRate)
}

/// Collects channel 0 of whatever the player node renders.
final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var gaps = 0
    private var nextTime: AVAudioFramePosition?

    func add(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        lock.lock()
        defer { lock.unlock() }
        if time.isSampleTimeValid {
            if let nextTime, nextTime != time.sampleTime { gaps += 1 }
            nextTime = time.sampleTime + AVAudioFramePosition(buffer.frameLength)
        }
        samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    func snapshot() -> (samples: [Float], gaps: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (samples, gaps)
    }
}

/// The captured stream must be the loop repeated back to back, sample for sample.
func verifyRepetition(_ y: [Float], loop x: [Float], sampleRate: Double) -> (ok: Bool, wraps: Int, detail: String) {
    let n = x.count
    let probe = 64
    guard n > probe, y.count > probe else { return (false, 0, "captura curta demais") }
    var start: Int?
    let limit = min(y.count - probe, Int(sampleRate * 2))
    search: for k in 0..<max(0, limit) where abs(y[k] - x[0]) < 1e-6 {
        for j in 1..<probe where abs(y[k + j] - x[j]) > 1e-6 { continue search }
        start = k
        break
    }
    guard let start else { return (false, 0, "início do loop não encontrado na saída") }
    let compared = y.count - start
    var mismatches = 0
    var firstBad = -1
    for i in 0..<compared where abs(y[start + i] - x[i % n]) > 1e-6 {
        mismatches += 1
        if firstBad < 0 { firstBad = i }
    }
    let wraps = compared / n
    var detail = "\(compared) amostras, \(wraps) emendas, \(mismatches) divergências"
    if firstBad >= 0 { detail += " (primeira na amostra \(firstBad))" }
    return (mismatches == 0 && wraps >= 2, wraps, detail)
}

func locate(_ pattern: ArraySlice<Float>, in y: [Float], from: Int = 0, limit: Int? = nil) -> Int? {
    let probe = pattern.count
    let first = pattern[pattern.startIndex]
    let last = min(y.count - probe, limit ?? y.count)
    guard last >= from else { return nil }
    search: for k in from...last where abs(y[k] - first) < 1e-6 {
        for (j, value) in pattern.enumerated() where abs(y[k + j] - value) > 1e-6 { continue search }
        return k
    }
    return nil
}

/// Output must be: loop A repeated, then (from frame T) B with A crossfading out, then B repeated.
func verifySwitch(_ y: [Float], from a: [Float], to b: [Float], crossfade x: Int, sampleRate: Double)
    -> (ok: Bool, atBoundary: Bool, secondsIntoA: Double?, detail: String) {
    let na = a.count, nb = b.count
    guard let startA = locate(a[0..<64], in: y, limit: Int(sampleRate * 2)) else {
        return (false, false, nil, "início do loop A não encontrado")
    }
    guard let pureB = locate(b[x..<(x + 64)], in: y, from: startA) else {
        return (false, false, nil, "loop B não encontrado")
    }
    let t = pureB - x
    var badA = 0, badFade = 0, badB = 0
    for i in startA..<t where abs(y[i] - a[(i - startA) % na]) > 1e-6 { badA += 1 }
    for k in 0..<x {
        let gIn = sin(Float.pi / 2 * Float(k) / Float(x))
        let gOut = cos(Float.pi / 2 * Float(k) / Float(x))
        let expected = b[k] * gIn + a[(t - startA + k) % na] * gOut
        if abs(y[t + k] - expected) > 1e-5 { badFade += 1 }
    }
    for i in (t + x)..<y.count where abs(y[i] - b[(i - t) % nb]) > 1e-6 { badB += 1 }
    let atBoundary = (t - startA) % na == 0
    let turnsB = (y.count - t) / nb
    let into = Double(t - startA) / sampleRate
    let detail = String(format: "troca em %.3f s do loop A (%@), %d voltas de B; divergências A/crossfade/B: %d/%d/%d",
                        into, atBoundary ? "fim exato da volta" : "no meio da volta", turnsB, badA, badFade, badB)
    return (badA == 0 && badFade == 0 && badB == 0 && turnsB >= 1, atBoundary, into, detail)
}

/// A repeated exactly up to the end of a turn, then never a run of silence.
func verifyHandOverIntoUnknown(_ y: [Float], from a: [Float], sampleRate: Double) -> (ok: Bool, detail: String) {
    let na = a.count
    guard let startA = locate(a[0..<64], in: y, limit: Int(sampleRate * 2)) else { return (false, "início do loop A não encontrado") }
    var t = startA
    while t < y.count, abs(y[t] - a[(t - startA) % na]) < 1e-6 { t += 1 }
    let boundary = (t - startA + 64) / na * na + startA   // A ends within a few samples of the turn end
    var longestSilence = 0, run = 0
    for i in t..<y.count {
        run = abs(y[i]) < 1e-4 ? run + 1 : 0
        longestSilence = max(longestSilence, run)
    }
    let ok = abs(t - boundary) < 64 && longestSilence < 8 && y.count - t > Int(sampleRate)
    return (ok, String(format: "A até %.3f s (fim da volta), maior trecho silencioso depois: %d amostras", Double(t - startA) / sampleRate, longestSilence))
}

func isWAV(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: 12), data.count == 12 else { return false }
    return String(data: data[0..<4], encoding: .ascii) == "RIFF" && String(data: data[8..<12], encoding: .ascii) == "WAVE"
}

func bitDepth(_ url: URL) -> Int {
    (try? AVAudioFile(forReading: url))?.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int ?? 0
}

// MARK: - Private aggregate devices (simulated plug / unplug)

func createAggregate(uid: String, name: String, subDeviceUID: String) -> AudioDeviceID? {
    let description: [String: Any] = [
        kAudioAggregateDeviceUIDKey: uid,
        kAudioAggregateDeviceNameKey: name,
        kAudioAggregateDeviceIsPrivateKey: 1,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: subDeviceUID]],
        kAudioAggregateDeviceMainSubDeviceKey: subDeviceUID,
    ]
    var id = AudioDeviceID(0)
    let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
    return status == noErr ? id : nil
}

func destroyAggregate(_ id: AudioDeviceID) {
    AudioHardwareDestroyAggregateDevice(id)
}

// MARK: - Checks

@MainActor
struct Checks {
    let report = Report()
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("JeskeLooperChecks-\(UUID().uuidString)", isDirectory: true)
    let offline = CommandLine.arguments.contains("--offline")

    func run() async -> Int32 {
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        storeChecks()
        trimChecks()
        shortcutChecks()
        writerChecks()
        rampChecks()
        resolveChecks()

        if offline {
            report.skip("Testes com hardware", "executado com --offline")
        } else {
            let devices = AudioHardware.devices()
            deviceChecks(devices)
            let ck = devices.first(where: \.isYamahaCK)
            let mic = devices.first { $0.uid == "BuiltInMicrophoneDevice" } ?? devices.first { $0.hasInput && !$0.isYamahaCK }
            let output = ck.flatMap { $0.hasOutput ? $0 : nil }
                ?? AudioHardware.defaultOutputDeviceID().flatMap { id in devices.first { $0.objectID == id } }
            if MicrophonePermission.current != .authorized {
                report.skip("Gravação real", "o processo não tem permissão de entrada de áudio")
            } else {
                if let ck { await inputChecks(device: ck, expectSignal: false) } else { report.skip("Gravação do CK61", "CK não conectado") }
                if let mic { await inputChecks(device: mic, expectSignal: true) }
            }
            if let output { await playerChecks(output: output) } else { report.skip("Reprodução", "nenhuma saída") }
            if MicrophonePermission.current == .authorized, let mic, let output {
                await controllerChecks(ck: ck, mic: mic, output: output)
            }
        }

        print("\n────────────────────────────────────────")
        print("Resultado: \(report.passed) passaram, \(report.failed.count) falharam, \(report.skipped.count) pulados")
        for f in report.failed { print("  FALHOU: \(f)") }
        for s in report.skipped { print("  PULADO: \(s)") }
        return report.failed.isEmpty ? 0 : 1
    }

    // MARK: Store

    func storeChecks() {
        report.section("Armazenamento (pasta temporária)")
        let dir = tmp.appendingPathComponent("store", isDirectory: true)
        let store = LoopStore(directory: dir)
        store.useTrash = false
        do {
            try store.load()
            report.check("Cria a pasta e abre vazia", store.loops.isEmpty && FileManager.default.fileExists(atPath: dir.path))

            func record(_ seconds: Double) throws -> LoopItem {
                let url = try store.newRecordingURL()
                try writeLoop(url, seconds: seconds, sampleRate: 44_100, channels: 2) { c, i in noise(c, i, seed: 7) }
                return try store.addRecording(at: url)
            }
            let a = try record(0.5)
            // A file the user put there by hand must not be overwritten.
            try writeLoop(dir.appendingPathComponent("Loop 002.wav"), seconds: 0.3, sampleRate: 44_100, channels: 2) { _, _ in 0.1 }
            let b = try record(0.7)
            report.check("Nomes sequenciais sem sobrescrever", a.name == "Loop 001" && b.name == "Loop 003" && b.fileName == "Loop 003.wav",
                         "\(a.name), \(b.name)")
            report.check("Metadados (duração, formato, canais)",
                         abs(a.duration - 0.5) < 0.001 && a.format == "WAV PCM 24 bits" && a.channels == 2 && a.sampleRate == 44_100,
                         "\(a.duration) s, \(a.format), \(a.channels) ch, \(a.sampleRate) Hz")

            let renamed = try store.rename(id: a.id, to: "Baixo / ponte: v2")
            report.check("Renomear move o arquivo e mantém o id",
                         renamed.id == a.id && renamed.name == "Baixo / ponte: v2" && renamed.fileName == "Baixo - ponte- v2.wav"
                         && FileManager.default.fileExists(atPath: dir.appendingPathComponent(renamed.fileName).path)
                         && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Loop 001.wav").path),
                         renamed.fileName)
            let caseOnly = try store.rename(id: a.id, to: "baixo / ponte: v2")
            report.check("Renomear só maiúsculas/minúsculas", caseOnly.fileName == "baixo - ponte- v2.wav"
                         && (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.contains("baixo - ponte- v2.wav") == true)
            var emptyRejected = false
            do { try store.rename(id: a.id, to: "   ") } catch { emptyRejected = true }
            report.check("Nome vazio é recusado", emptyRejected)

            let reopened = LoopStore(directory: dir)
            try reopened.load()
            let names = reopened.loops.map(\.name)
            report.check("Reabrir recupera a lista", names == ["baixo / ponte: v2", "Loop 002", "Loop 003"],
                         names.joined(separator: ", ") + " (Loop 002 foi adotado da pasta)")

            try store.delete(id: b.id)
            report.check("Excluir remove arquivo e entrada",
                         !store.loops.contains { $0.id == b.id } && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Loop 003.wav").path))
            let next = try record(0.2)
            report.check("Número de loop não é reaproveitado após exclusão", next.name == "Loop 004", next.name)

            // Recovery: missing file, stale temp file, corrupt index.
            try FileManager.default.removeItem(at: dir.appendingPathComponent("Loop 004.wav"))
            FileManager.default.createFile(atPath: dir.appendingPathComponent(".gravando-teste.wav").path, contents: Data([1, 2, 3]))
            let recovered = LoopStore(directory: dir)
            recovered.useTrash = false
            try recovered.load()
            report.check("Entrada sem arquivo é removida ao abrir", !recovered.loops.contains { $0.name == "Loop 004" } && !recovered.loadNotes.isEmpty,
                         recovered.loadNotes.joined(separator: " "))
            report.check("Gravação interrompida (temporária) é descartada",
                         !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".gravando-teste.wav").path))
            let json = try String(contentsOf: dir.appendingPathComponent("loops.json"), encoding: .utf8)
            report.check("Datas salvas em UTC com milissegundos", json.range(of: #""createdAt" : "\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z""#,
                                                                            options: .regularExpression) != nil)
            let legacy = json.replacingOccurrences(of: #"(\.\d{3})Z""#, with: "$1\"", options: .regularExpression)
            try legacy.write(to: dir.appendingPathComponent("loops.json"), atomically: true, encoding: .utf8)
            let legacyStore = LoopStore(directory: dir)
            try legacyStore.load()
            let sameDates = legacyStore.loops.count == recovered.loops.count
                && zip(legacyStore.loops, recovered.loops).allSatisfy { abs($0.createdAt.timeIntervalSince($1.createdAt)) < 0.001 }
            report.check("Lê índice antigo (data sem “Z”)", sameDates && legacyStore.loadNotes.isEmpty)
            try Data("{ quebrado".utf8).write(to: dir.appendingPathComponent("loops.json"))
            let rebuilt = LoopStore(directory: dir)
            try rebuilt.load()
            report.check("Índice danificado é reconstruído a partir dos arquivos", rebuilt.loops.count == recovered.loops.count,
                         "\(rebuilt.loops.count) loops")
        } catch {
            report.check("Armazenamento sem erros", false, error.localizedDescription)
        }
    }

    // MARK: Silence trimming

    func trimChecks() {
        report.section("Corte do silêncio nas bordas")
        let rate = 44_100.0
        let url = tmp.appendingPathComponent("edges.wav")
        do {
            // 0,5 s silence + 1,0 s sound + 0,3 s silence.
            try writeLoop(url, seconds: 1.8, sampleRate: rate, channels: 2) { c, i in
                (22_050..<66_150).contains(i) ? tones(c, i, sampleRate: rate) : 0
            }
            let original = try readAll(url).channels
            guard let plan = try SilenceTrimmer.plan(for: url, leading: true, trailing: true) else {
                report.check("Encontra o som", false)
                return
            }
            report.check("Encontra onde o som começa e termina",
                         abs(plan.removedStart - 0.49) < 0.002 && abs(plan.removedEnd - 0.27) < 0.002,
                         String(format: "corta %.3f s no início e %.3f s no fim", plan.removedStart, plan.removedEnd))
            let out = tmp.appendingPathComponent("edges-trimmed.wav")
            try SilenceTrimmer.write(plan, from: url, to: out)
            let trimmed = try readAll(out).channels
            let exact = trimmed.indices.allSatisfy { c in
                trimmed[c].enumerated().allSatisfy { abs($1 - original[c][Int(plan.start) + $0]) < 1e-7 }
            }
            report.check("Arquivo cortado é cópia exata do trecho, em WAV 24 bits", exact && isWAV(out) && bitDepth(out) == 24
                         && trimmed[0].count == Int(plan.end - plan.start), "\(trimmed[0].count) quadros")
            let leadingOnly = try SilenceTrimmer.plan(for: url, leading: true, trailing: false)
            report.check("Só o início, quando o fim está desligado", leadingOnly?.end == leadingOnly?.total && (leadingOnly?.removedStart ?? 0) > 0.4)

            let silent = tmp.appendingPathComponent("silent.wav")
            try writeLoop(silent, seconds: 0.5, sampleRate: rate, channels: 2) { _, _ in 0 }
            report.check("Arquivo todo em silêncio é reconhecido", try SilenceTrimmer.plan(for: silent, leading: true, trailing: true) == nil)
            let full = tmp.appendingPathComponent("full.wav")
            try writeLoop(full, seconds: 0.5, sampleRate: rate, channels: 2) { c, i in tones(c, i + 100, sampleRate: rate) }
            report.check("Sem silêncio nas bordas: nada a cortar",
                         try SilenceTrimmer.plan(for: full, leading: true, trailing: true)?.changesNothing == true)
        } catch {
            report.check("Corte de silêncio", false, error.localizedDescription)
        }
    }

    // MARK: Shortcuts

    func shortcutChecks() {
        report.section("Teclas de atalho")
        var settings = ShortcutSettings.standard
        report.check("Espaço grava, ↩ repete, Esc para", settings.command(keyCode: KeyCodes.space, modifiers: []) == .toggleRecording
                     && settings.command(keyCode: KeyCodes.returnKey, modifiers: []) == .playSelected
                     && settings.command(keyCode: KeyCodes.keypadEnter, modifiers: []) == .playSelected
                     && settings.command(keyCode: KeyCodes.escape, modifiers: []) == .stopPlayback)
        report.check("Teclas 1–9 (fileira e teclado numérico) apontam para os loops",
                     KeyCodes.loopNumber(forKeyCode: 18) == 1 && KeyCodes.loopNumber(forKeyCode: 25) == 9
                     && KeyCodes.loopNumber(forKeyCode: 83) == 1 && KeyCodes.loopNumber(forKeyCode: 92) == 9
                     && KeyCodes.loopNumber(forKeyCode: 29) == nil)
        settings.set(KeyShortcut(keyCode: KeyCodes.space, key: "Espaço"), for: .stopPlayback)
        report.check("Tecla repetida passa para a nova ação", settings.command(keyCode: KeyCodes.space, modifiers: []) == .stopPlayback
                     && settings.shortcut(for: .toggleRecording) == nil)
        let option = KeyShortcut(keyCode: 15, modifiers: [.option], key: "R")
        settings.set(option, for: .toggleRecording)
        report.check("⌥ faz parte do atalho", settings.command(keyCode: 15, modifiers: [.option]) == .toggleRecording
                     && settings.command(keyCode: 15, modifiers: []) == nil && option.label == "⌥R")
        report.check("Números reservados para os loops", settings.problem(with: KeyShortcut(keyCode: 18, key: "1")) != nil)
        let suite = "com.guilhermejeske.JeskeLooper.checks.shortcuts"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        report.check("Sem ajustes salvos: teclas padrão", ShortcutSettings.load(from: defaults) == .standard)
        settings.worksInBackground = true
        settings.save(to: defaults)
        report.check("Teclas lembradas entre sessões", ShortcutSettings.load(from: defaults) == settings)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    // MARK: Writer / window math

    func writerChecks() {
        report.section("Arquivo de gravação e recorte por tempo")
        let url = tmp.appendingPathComponent("writer.wav")
        do {
            try writeLoop(url, seconds: 1.0, sampleRate: 48_000, channels: 2) { c, i in c == 0 ? 0.5 * sin(Float(i) * 0.05) : -0.25 }
            let back = try readAll(url)
            let left = back.channels[0], right = back.channels[1]
            let maxErr = zip(left.indices, left).map { abs($1 - 0.5 * sin(Float($0) * 0.05)) }.max() ?? 1
            report.check("WAV 24 bits estéreo finalizado e legível",
                         isWAV(url) && bitDepth(url) == 24 && back.sampleRate == 48_000 && left.count == 48_000,
                         "\(left.count) quadros, \(back.sampleRate) Hz, \(bitDepth(url)) bits")
            report.check("Canais L/R preservados", maxErr < 1e-6 && right.allSatisfy { abs($0 + 0.25) < 1e-6 },
                         String(format: "erro máx %.1e", maxErr))
        } catch {
            report.check("Escrita WAV", false, error.localizedDescription)
        }

        let sr = 44_100.0
        let buffers = (0..<10).map { Double($0) * 4410 / sr }
        let start = 0.123_456, end = 0.734_567
        var total = 0
        var reached = false
        for b in buffers {
            let r = RecordingWindowMath.frames(bufferStart: b, frameCount: 4410, sampleRate: sr, windowStart: start, windowEnd: end)
            total += r.range.count
            if r.reachedEnd { reached = true; break }
        }
        let expected = Int((end * sr).rounded(.up)) - Int((start * sr).rounded(.up))
        report.check("Recorte no instante do clique (precisão de amostra)", total == expected && reached, "\(total) quadros, esperado \(expected)")
    }

    // MARK: Seam ramps

    func rampChecks() {
        report.section("Rampas na emenda")
        let ramp = EdgeRamp(length: 32)
        let format = LoopAudioFormat.processingFormat(sampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1000)!
        buffer.frameLength = 1000
        for c in 0..<2 { for i in 0..<1000 { buffer.floatChannelData![c][i] = 1 } }
        ramp.apply(to: buffer, startFrame: 0, totalFrames: 1000)
        let d = buffer.floatChannelData![0]
        report.check("Rampa só nas bordas e duração inalterada",
                     buffer.frameLength == 1000 && d[0] == 0 && d[999] == 0 && d[500] == 1 && d[31] > 0.9 && d[968] > 0.9)

        do {
            let sine = tmp.appendingPathComponent("sine.wav")
            try writeLoop(sine, seconds: 1.0, sampleRate: 44_100, channels: 2) { _, i in 0.5 * sin(2 * .pi * 441 * Float(i) / 44_100) }
            let noisy = tmp.appendingPathComponent("noisy.wav")
            try writeLoop(noisy, seconds: 1.0, sampleRate: 44_100, channels: 2) { c, i in tones(c, i, sampleRate: 44_100) }
            let sineRamp = EdgeRamp.detect(in: try AVAudioFile(forReading: sine, commonFormat: .pcmFormatFloat32, interleaved: false))
            let noisyRamp = EdgeRamp.detect(in: try AVAudioFile(forReading: noisy, commonFormat: .pcmFormatFloat32, interleaved: false))
            report.check("Emenda contínua: sem rampa", sineRamp == nil)
            report.check("Emenda com salto: rampa de ~3 ms", noisyRamp?.length == 132, "\(noisyRamp?.length ?? 0) quadros")
        } catch {
            report.check("Detecção de emenda", false, error.localizedDescription)
        }
    }

    // MARK: Device resolution

    func resolveChecks() {
        report.section("Escolha persistente de dispositivo")
        let ck = AudioDevice(objectID: 10, uid: "AppleUSBAudioEngine:Yamaha Corporation:CK Series:140000:1,2", name: "CK Series",
                             manufacturer: "Yamaha Corporation", inputChannels: 2, outputChannels: 2, nominalSampleRate: 44_100)
        let ckOtherPort = AudioDevice(objectID: 11, uid: "AppleUSBAudioEngine:Yamaha Corporation:CK Series:120000:1,2", name: "CK Series",
                                      manufacturer: "Yamaha Corporation", inputChannels: 2, outputChannels: 2, nominalSampleRate: 44_100)
        let mic = AudioDevice(objectID: 12, uid: "BuiltInMicrophoneDevice", name: "Microfone (MacBook Air)",
                              manufacturer: "Apple Inc.", inputChannels: 1, outputChannels: 0, nominalSampleRate: 48_000)
        let saved = SavedDevice(ck)
        report.check("UID igual é encontrado", LooperController.resolve(saved, in: [mic, ck])?.objectID == 10)
        report.check("CK em outra porta USB (UID novo) é reconhecido", LooperController.resolve(saved, in: [mic, ckOtherPort])?.objectID == 11)
        report.check("CK ausente não cai para o microfone interno", LooperController.resolve(saved, in: [mic]) == nil)
        report.check("Dois CKs iguais sem UID conhecido: não adivinha", LooperController.resolve(saved, in: [ckOtherPort, AudioDevice(
            objectID: 13, uid: "x", name: "CK Series", manufacturer: "Yamaha Corporation", inputChannels: 2, outputChannels: 2,
            nominalSampleRate: 44_100)]) == nil)
    }

    // MARK: Hardware

    func deviceChecks(_ devices: [AudioDevice]) {
        report.section("Dispositivos reais (Core Audio)")
        for d in devices {
            report.note("\(d.name) [\(d.manufacturer)] in \(d.inputChannels) / out \(d.outputChannels) · \(LooperFormat.sampleRate(d.nominalSampleRate)) · \(d.uid)")
        }
        report.check("Enumera dispositivos", !devices.isEmpty, "\(devices.count) encontrados")
        if let ck = devices.first(where: \.isYamahaCK) {
            report.check("CK61 aparece como entrada e saída", ck.hasInput && ck.hasOutput, "\(ck.name): \(ck.inputChannels) in / \(ck.outputChannels) out")
        } else {
            report.skip("CK61 conectado", "nenhum dispositivo “CK Series” encontrado")
        }
        let inputsOnly = devices.filter(\.hasInput).allSatisfy { $0.inputChannels > 0 }
        let outputsOnly = devices.filter(\.hasOutput).allSatisfy { $0.outputChannels > 0 }
        report.check("Filtro de entradas e saídas por canais", inputsOnly && outputsOnly)
    }

    func inputChecks(device: AudioDevice, expectSignal: Bool) async {
        report.section("Gravação real: \(device.name)")
        let input = InputEngine()
        let started: Result<InputFormatInfo, Error> = await withCheckedContinuation { cont in
            input.start(device: device) { cont.resume(returning: $0) }
        }
        guard case .success(let info) = started else {
            if case .failure(let error) = started { report.check("Inicia entrada", false, error.localizedDescription) }
            return
        }
        report.check("Inicia entrada no dispositivo escolhido", true,
                     "\(LooperFormat.sampleRate(info.sampleRate)), \(info.deviceChannels) canais no aparelho, \(info.recordedChannels) gravados")
        await pause(0.3)
        let url = tmp.appendingPathComponent("real-\(device.objectID).wav")
        let t0 = mach_absolute_time()
        do { try input.beginRecording(to: url, hostTime: t0) } catch {
            report.check("Começa a gravar", false, error.localizedDescription)
            input.stop()
            return
        }
        await pause(1.6)
        let t1 = mach_absolute_time()
        let result: RecordingResult = await withCheckedContinuation { cont in
            input.finishRecording(hostTime: t1, waitForTail: true) { cont.resume(returning: $0) }
        }
        input.stop()
        let expected = AVAudioTime.seconds(forHostTime: t1) - AVAudioTime.seconds(forHostTime: t0)
        report.check("Duração bate com o intervalo entre os cliques", abs(result.duration - expected) < 0.002,
                     String(format: "%.4f s gravados, %.4f s esperados", result.duration, expected))
        let file = try? AVAudioFile(forReading: url)
        report.check("Arquivo finalizado: WAV 24 bits, quadros corretos",
                     isWAV(url) && bitDepth(url) == 24 && file?.length == result.frames
                     && file?.fileFormat.channelCount == AVAudioChannelCount(info.recordedChannels)
                     && file?.fileFormat.sampleRate == info.sampleRate,
                     "\(file?.length ?? -1) quadros, \(file?.fileFormat.channelCount ?? 0) canais")
        let peakDB = result.peak > 0 ? 20 * log10(result.peak) : -Float.infinity
        if expectSignal {
            report.check("Sinal real captado", result.peak > 0.000_02, String(format: "pico %.1f dBFS", peakDB))
        } else {
            report.note(String(format: "Pico captado: %.1f dBFS (sem tocar o teclado, silêncio é o esperado)", peakDB))
        }
        try? FileManager.default.removeItem(at: url)
    }

    func playerChecks(output: AudioDevice) async {
        report.section("Reprodução em loop (saída: \(output.name), volume 0)")
        let rate = output.nominalSampleRate > 0 ? output.nominalSampleRate : 44_100
        var token = 0

        func makePlayer(memoryLimit: Double = 45, ramps: LoopPlayer.SeamRamps = .never) -> (LoopPlayer, Capture) {
            let player = LoopPlayer()
            player.setVolume(0)
            player.seamRamps = ramps
            player.memoryLimitSeconds = memoryLimit
            let capture = Capture()
            player.debugTap = { [capture] in capture.add($0, $1) }
            return (player, capture)
        }
        func play(_ player: LoopPlayer, _ url: URL, _ transition: LoopTransition) async -> Result<PlaybackInfo, Error> {
            token += 1
            let t = token
            return await withCheckedContinuation { cont in
                player.play(url: url, token: t, on: output, transition: transition) { cont.resume(returning: $0) }
            }
        }
        func stop(_ player: LoopPlayer) async {
            await withCheckedContinuation { cont in player.stop { cont.resume() } }
        }

        do {
            let a = tmp.appendingPathComponent("A.wav")
            try writeLoop(a, seconds: 2.0, sampleRate: rate, channels: 2) { c, i in noise(c, i, seed: 11) }
            let b = tmp.appendingPathComponent("B.wav")
            try writeLoop(b, seconds: 1.3, sampleRate: rate, channels: 2) { c, i in noise(c, i, seed: 23) }
            let smooth = tmp.appendingPathComponent("C.wav")
            try writeLoop(smooth, seconds: 1.3, sampleRate: rate, channels: 2) { c, i in tones(c, i, sampleRate: rate) }
            let xa = try readAll(a).channels[0], xb = try readAll(b).channels[0], xc = try readAll(smooth).channels[0]
            let crossfade = Int((0.01 * rate).rounded())

            // One loop in memory.
            var (player, capture) = makePlayer()
            if case .success(let info) = await play(player, a, .restart) {
                report.check("Loop curto vai para a memória", info.strategy == .memory)
            } else { report.check("Reproduz loop curto", false) }
            await pause(5.5)
            var snap = capture.snapshot()
            var v = verifyRepetition(snap.samples, loop: xa, sampleRate: rate)
            report.check("Repetição contínua, sem pausas (memória)", v.ok && snap.gaps == 0, v.detail)
            report.check("Um único player na engine", player.attachedPlayerCount() == 1)
            await stop(player)
            report.check("Parar libera a reprodução", player.attachedPlayerCount() == 0)

            // Hand-over at the end of the turn.
            (player, capture) = makePlayer()
            var announced: [(token: Int, at: Date)] = []
            player.onAudibleLoopChanged = { announced.append(($0, Date())) }
            _ = await play(player, a, .restart)
            let tokenA = token
            await pause(0.7)
            let positionA = player.position()
            report.check("Posição na volta é informada", positionA?.token == tokenA && (positionA?.progress ?? -1) > 0.2
                         && (positionA?.progress ?? 2) < 0.6 && abs((positionA?.cycleSeconds ?? 0) - 2.0) < 0.01,
                         positionA.map { String(format: "%.0f%% de %.2f s", $0.progress * 100, $0.cycleSeconds) } ?? "nenhuma")
            if case .success(let info) = await play(player, b, .atCycleEnd) {
                report.check("Pedido de troca fica na fila até o fim da volta", info.transition == .atCycleEnd)
            }
            let tokenB = token
            report.check("Antes do fim da volta, ainda toca o loop atual", player.position()?.token == tokenA)
            await pause(4.6)
            snap = capture.snapshot()
            var w = verifySwitch(snap.samples, from: xa, to: xb, crossfade: crossfade, sampleRate: rate)
            report.check("Troca no fim da volta: sem silêncio, emenda exata", w.ok && w.atBoundary && snap.gaps == 0, w.detail)
            report.check("Aviso de troca na hora em que o novo loop começa a soar",
                         announced.last?.token == tokenB && player.position()?.token == tokenB,
                         announced.isEmpty ? "sem aviso" : "aviso recebido")
            await stop(player)

            // Immediate hand-over with crossfade.
            (player, capture) = makePlayer()
            _ = await play(player, a, .restart)
            await pause(0.9)
            _ = await play(player, b, .immediate)
            await pause(3.4)
            snap = capture.snapshot()
            w = verifySwitch(snap.samples, from: xa, to: xb, crossfade: crossfade, sampleRate: rate)
            report.check("Troca imediata: crossfade sem silêncio, sem esperar a volta",
                         w.ok && !w.atBoundary && (w.secondsIntoA ?? 9) < 1.4 && snap.gaps == 0, w.detail)
            await stop(player)

            // Queue cancelled: the current loop simply continues.
            (player, capture) = makePlayer()
            _ = await play(player, a, .restart)
            await pause(0.5)
            _ = await play(player, b, .atCycleEnd)
            player.cancelQueued()
            await pause(4.4)
            snap = capture.snapshot()
            v = verifyRepetition(snap.samples, loop: xa, sampleRate: rate)
            report.check("Fila cancelada: continua o mesmo loop, sem trocar", v.ok && snap.gaps == 0, v.detail)
            await stop(player)

            // Long loops streamed from disk, including a hand-over between two of them.
            (player, capture) = makePlayer(memoryLimit: 0.5)
            if case .success(let info) = await play(player, a, .restart) {
                report.check("Loop longo usa leitura contínua do disco", info.strategy == .streaming)
            }
            await pause(5.5)
            snap = capture.snapshot()
            v = verifyRepetition(snap.samples, loop: xa, sampleRate: rate)
            report.check("Repetição contínua, sem pausas (leitura do disco)", v.ok && snap.gaps == 0, v.detail)
            await stop(player)

            (player, capture) = makePlayer(memoryLimit: 0.5)
            _ = await play(player, a, .restart)
            await pause(0.6)
            _ = await play(player, b, .atCycleEnd)
            await pause(4.6)
            snap = capture.snapshot()
            w = verifySwitch(snap.samples, from: xa, to: xb, crossfade: crossfade, sampleRate: rate)
            report.check("Troca no fim da volta entre loops lidos do disco", w.ok && w.atBoundary && snap.gaps == 0, w.detail)
            await stop(player)

            // Automatic seam ramp: still gapless and the same length.
            (player, capture) = makePlayer(ramps: .automatic)
            if case .success(let info) = await play(player, smooth, .restart) {
                report.check("Rampa aplicada quando a emenda tem salto", info.seamRampApplied)
            }
            await pause(4.0)
            snap = capture.snapshot()
            let ramp = EdgeRamp(length: EdgeRamp.defaultLength(sampleRate: rate))
            let expected = xc.enumerated().map { $1 * ramp.gain(atFrame: Int64($0), totalFrames: Int64(xc.count)) }
            v = verifyRepetition(snap.samples, loop: expected, sampleRate: rate)
            report.check("Com rampa: mesma duração e sem silêncio extra", v.ok && snap.gaps == 0, v.detail)
            await stop(player)

            // Loop at another sample rate (mono): converted, and the hand-over is still gapless.
            let otherRate = rate == 48_000 ? 44_100.0 : 48_000.0
            let mono = tmp.appendingPathComponent("mono.wav")
            try writeLoop(mono, seconds: 1.0, sampleRate: otherRate, channels: 1) { _, i in
                0.4 * sin(2 * .pi * 300 * Float(i) / Float(otherRate)) + 0.05
            }
            (player, capture) = makePlayer()
            _ = await play(player, a, .restart)
            await pause(0.5)
            let converted = await play(player, mono, .atCycleEnd)
            await pause(2.8)
            snap = capture.snapshot()
            if case .success(let info) = converted {
                let check = verifyHandOverIntoUnknown(snap.samples, from: xa, sampleRate: rate)
                report.check("Converte taxa e mono → estéreo, trocando sem silêncio",
                             check.ok && abs(info.fileSampleRate - otherRate) < 1 && abs(info.outputSampleRate - rate) < 1,
                             "arquivo \(LooperFormat.sampleRate(info.fileSampleRate)) mono → saída \(LooperFormat.sampleRate(info.outputSampleRate)); \(check.detail)")
            } else if case .failure(let error) = converted {
                report.check("Converte taxa de amostragem", false, error.localizedDescription)
            }
            await stop(player)
        } catch {
            report.check("Preparar arquivos de teste", false, error.localizedDescription)
        }
    }

    // MARK: Whole app flow

    func controllerChecks(ck: AudioDevice?, mic: AudioDevice, output: AudioDevice) async {
        report.section("Fluxo completo do app (controlador real, volume 0)")
        let suite = "com.guilhermejeske.JeskeLooper.checks"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let dir = tmp.appendingPathComponent("app-loops", isDirectory: true)
        let store = LoopStore(directory: dir)
        store.useTrash = false
        let c = LooperController(store: store, defaults: defaults)
        c.setVolume(0)
        c.start()

        if let ck {
            report.check("Primeiro uso escolhe o CK61 como entrada e saída", c.savedInput?.uid == ck.uid && c.savedOutput?.uid == ck.uid)
            report.check("Entrada pronta no CK61", await waitUntil(3) { c.inputIsReady }, "\(c.inputStatus)")
            c.startRecording()
            report.check("Estado gravando", c.isRecording)
            await pause(1.0)
            c.stopRecording()
            _ = await waitUntil(3) { c.mode != .saving }
            if c.loops.isEmpty {
                report.check("Gravação sem som não é salva", c.banner?.text.contains("Nenhum som") == true, c.banner?.text ?? "")
            } else {
                report.note("O CK enviou som durante o teste; a gravação foi salva normalmente.")
                c.stopPlayback()
                if let id = c.loops.first?.id { c.delete(loopID: id) }
            }
        }

        c.selectOutput(uid: output.uid)
        c.selectInput(uid: mic.uid)
        report.check("Entrada pronta (\(mic.name))", await waitUntil(3) { c.inputIsReady }, "\(c.inputStatus)")

        // Too short.
        c.startRecording()
        await pause(0.05)
        c.stopRecording()
        _ = await waitUntil(3) { c.mode == .idle }
        report.check("Gravação curta demais não é salva", c.loops.isEmpty && c.banner?.text.contains("curta") == true, c.banner?.text ?? "")

        // Record → auto-select → auto-repeat.
        c.startRecording()
        let recordingMode = c.mode
        report.check("Não grava duas vezes ao mesmo tempo", { c.startRecording(); return c.mode == recordingMode }())
        if let ck { c.selectInput(uid: ck.uid) }
        report.check("Trocar de entrada é bloqueado durante a gravação", c.savedInput?.uid == mic.uid)
        await pause(1.5)
        c.stopRecording()
        report.check("Estado salvando após Parar gravação", c.mode == .saving)
        _ = await waitUntil(4) { c.isPlaying }
        let first = c.loops.first
        report.check("Salva, seleciona e repete automaticamente",
                     first?.name == "Loop 001" && c.selectedLoopID == first?.id && c.playingLoopID == first?.id,
                     first.map { "\($0.name), \(LooperFormat.duration($0.duration))" } ?? "nenhum loop")
        report.check("Reprodução iniciada na saída escolhida", await waitUntil(3) { c.lastPlaybackInfo != nil })

        // New recording (keyboard command) stops playback first.
        c.perform(.toggleRecording)
        report.check("Tecla de gravar: começa a gravar e para a reprodução atual", c.isRecording && !c.isPlaying)
        _ = await waitUntil(2) { c.player.attachedPlayerCount() == 0 }
        report.check("Nenhum loop tocando durante a gravação", c.player.attachedPlayerCount() == 0)
        await pause(1.2)
        c.perform(.toggleRecording)
        report.check("Tecla de gravar de novo: para e salva", c.mode == .saving)
        _ = await waitUntil(4) { c.isPlaying }
        let second = c.loops.last
        report.check("Segundo loop repete automaticamente", second?.name == "Loop 002" && c.playingLoopID == second?.id)

        if let first, let second {
            report.check("Modo padrão: trocar no fim da volta", c.switchMode == .atCycleEnd)
            c.play(loopID: first.id)
            report.check("Escolher outro loop: fica como Próximo", c.queuedLoopID == first.id && c.playingLoopID == second.id)
            let switched = await waitUntil(second.duration + 1.5) { c.playingLoopID == first.id && c.queuedLoopID == nil }
            report.check("Troca sozinha no fim da volta", switched && c.player.attachedPlayerCount() == 1)
            c.play(loopID: second.id)
            c.play(loopID: second.id)
            report.check("Escolher o Próximo de novo troca na hora", c.playingLoopID == second.id && c.queuedLoopID == nil)
            await pause(0.3)
            c.play(loopID: first.id)
            c.play(loopID: second.id)
            report.check("Escolher o loop atual cancela a fila", c.queuedLoopID == nil && c.playingLoopID == second.id)
            await pause(second.duration + 0.6)
            report.check("Fila cancelada: o loop atual continua", c.playingLoopID == second.id && c.queuedLoopID == nil)

            c.perform(.selectPrevious)
            report.check("↑ seleciona o loop anterior", c.selectedLoopID == first.id)
            c.perform(.selectPrevious)
            report.check("↑ no primeiro loop fica nele", c.selectedLoopID == first.id)
            c.perform(.playSelected, immediate: true)
            report.check("⇧↩ repete o selecionado na hora", c.playingLoopID == first.id)
            c.playLoop(number: 2)
            report.check("Tecla 2 põe o loop 2 como Próximo", c.queuedLoopID == second.id)
            c.playLoop(number: 2, immediate: true)
            report.check("⇧2 troca para o loop 2 na hora", c.playingLoopID == second.id && c.queuedLoopID == nil)
            c.playLoop(number: 7)
            report.check("Tecla de loop inexistente não faz nada", c.playingLoopID == second.id && c.queuedLoopID == nil)
            c.switchMode = .immediate
            c.play(loopID: first.id)
            report.check("Modo “trocar na hora” troca sem fila", c.playingLoopID == first.id && c.queuedLoopID == nil)
            c.switchMode = .atCycleEnd
            await pause(0.3)
            report.check("Só um player depois das trocas", c.player.attachedPlayerCount() == 1)
            c.perform(.stopPlayback)
        }
        c.stopPlayback()
        _ = await waitUntil(2) { c.player.attachedPlayerCount() == 0 }
        report.check("Parar encerra a repetição", c.mode == .idle && c.player.attachedPlayerCount() == 0)
        c.perform(.volumeUp)
        c.perform(.volumeUp)
        let raised = c.volume
        c.perform(.volumeDown)
        c.perform(.volumeDown)
        c.perform(.volumeDown)
        report.check("← → mudam o volume em passos de 5%", abs(raised - 0.1) < 0.001 && c.volume == 0, "\(raised) → \(c.volume)")

        if let first, let second {
            c.rename(loopID: first.id, to: "Groove A")
            report.check("Renomear pelo app", c.loops.first?.name == "Groove A"
                         && FileManager.default.fileExists(atPath: dir.appendingPathComponent("Groove A.wav").path))
            c.play(loopID: second.id)
            await pause(0.3)
            c.delete(loopID: second.id)
            report.check("Excluir o loop que está tocando para a reprodução e remove o arquivo",
                         c.mode == .idle && c.loops.count == 1 && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Loop 002.wav").path))
        }

        // Reopen with the same folder and preferences (plus a file with silent edges dropped in the folder).
        c.shutdown()
        await pause(0.3)
        let edges = dir.appendingPathComponent("Com silêncio.wav")
        try? writeLoop(edges, seconds: 2.0, sampleRate: 44_100, channels: 2) { c, i in
            (22_050..<66_150).contains(i) ? tones(c, i, sampleRate: 44_100) : 0
        }
        let reopenedStore = LoopStore(directory: dir)
        reopenedStore.useTrash = false
        let c2 = LooperController(store: reopenedStore, defaults: defaults)
        c2.start()
        report.check("Reabrir: lista de loops restaurada", c2.loops.map(\.name) == ["Groove A", "Com silêncio"],
                     c2.loops.map(\.name).joined(separator: ", "))
        if let silent = c2.loops.first(where: { $0.name == "Com silêncio" }) {
            c2.trimSilence(loopID: silent.id)
            report.check("Cortando silêncio: loop bloqueado para outras ações", c2.processingLoopID == silent.id && !c2.canEditLoops)
            _ = await waitUntil(5) { c2.processingLoopID == nil }
            let trimmed = c2.loops.first { $0.id == silent.id }
            report.check("Cortar silêncio das bordas de um loop salvo",
                         abs((trimmed?.duration ?? 0) - 1.04) < 0.002 && trimmed?.fileName == "Com silêncio.wav"
                         && c2.banner?.text.contains("0,49 s no início") == true,
                         "\(trimmed.map { LooperFormat.duration($0.duration) } ?? "?") — \(c2.banner?.text ?? "")")
            let reread = (try? AVAudioFile(forReading: dir.appendingPathComponent("Com silêncio.wav")))?.length
            report.check("Arquivo e metadados atualizados juntos", reread == trimmed?.frameCount)
        }
        if let groove = c2.loops.first(where: { $0.name == "Groove A" }) {
            c2.trimSilence(loopID: groove.id)
            _ = await waitUntil(5) { c2.processingLoopID == nil }
            report.check("Loop sem silêncio nas bordas fica igual", c2.loops.first?.duration == groove.duration
                         && c2.banner?.text.contains("não tem silêncio") == true, c2.banner?.text ?? "")
        }
        report.check("Reabrir: entrada, saída e volume lembrados",
                     c2.savedInput?.uid == mic.uid && c2.savedOutput?.uid == output.uid && c2.volume == 0)
        _ = await waitUntil(3) { c2.inputIsReady }

        await disconnectChecks(c2, mic: mic, speakerUID: "BuiltInSpeakerDevice")
        c2.shutdown()
        await pause(0.3)
    }

    func disconnectChecks(_ c: LooperController, mic: AudioDevice, speakerUID: String) async {
        report.section("Desconexão (dispositivo agregado privado criado e destruído durante o uso)")
        let outUID = "com.guilhermejeske.JeskeLooper.checks.out"
        let inUID = "com.guilhermejeske.JeskeLooper.checks.in"

        guard var outID = createAggregate(uid: outUID, name: "Jeske Teste Saída", subDeviceUID: speakerUID) else {
            report.skip("Desconexão da saída", "não foi possível criar dispositivo agregado")
            return
        }
        let appeared = await waitUntil(3) { c.outputDevices.contains { $0.uid == outUID } }
        report.check("Conexão detectada automaticamente", appeared)
        guard appeared, let loop = c.loops.first else { destroyAggregate(outID); return }
        c.selectOutput(uid: outUID)
        c.play(loopID: loop.id)
        _ = await waitUntil(3) { c.lastPlaybackInfo != nil && c.isPlaying }
        await pause(0.8)
        let t0 = Date()
        destroyAggregate(outID)
        let stopped = await waitUntil(5) { c.mode == .idle }
        report.check("Saída desconectada: repetição para com segurança", stopped && c.outputStatus == .disconnected,
                     String(format: "em %.2f s; aviso: %@", Date().timeIntervalSince(t0), c.banner?.text ?? "nenhum"))
        report.check("Saída desconectada: escolha mantida, sem troca silenciosa", c.savedOutput?.uid == outUID)
        if let again = createAggregate(uid: outUID, name: "Jeske Teste Saída", subDeviceUID: speakerUID) {
            outID = again
            report.check("Saída reconectada volta a ficar pronta", await waitUntil(3) {
                if case .ready = c.outputStatus { return true } else { return false }
            })
            report.check("Reconexão não volta a tocar sozinha", c.mode == .idle)
            destroyAggregate(outID)
        }

        guard var inID = createAggregate(uid: inUID, name: "Jeske Teste Entrada", subDeviceUID: mic.uid) else {
            report.skip("Desconexão da entrada", "não foi possível criar dispositivo agregado")
            return
        }
        _ = await waitUntil(3) { c.inputDevices.contains { $0.uid == inUID } }
        c.selectInput(uid: inUID)
        report.check("Entrada agregada pronta", await waitUntil(3) { c.inputIsReady }, "\(c.inputStatus)")
        let countBefore = c.loops.count
        c.startRecording()
        await pause(1.2)
        destroyAggregate(inID)
        let finished = await waitUntil(5) { c.mode == .idle && c.inputStatus == .disconnected }
        report.check("Entrada desconectada durante a gravação: para e salva o trecho",
                     finished && c.loops.count == countBefore + 1 && !c.isPlaying,
                     c.banner?.text ?? "sem aviso")
        report.check("Não troca para o microfone interno", c.savedInput?.uid == inUID && c.activeInputDevice == nil)
        if let again = createAggregate(uid: inUID, name: "Jeske Teste Entrada", subDeviceUID: mic.uid) {
            inID = again
            report.check("Entrada reconectada volta sozinha", await waitUntil(4) { c.inputIsReady }, "\(c.inputStatus)")
            c.selectInput(uid: nil)
            await pause(0.3)
            destroyAggregate(inID)
        }
    }
}

let code = await Checks().run()
exit(code)
