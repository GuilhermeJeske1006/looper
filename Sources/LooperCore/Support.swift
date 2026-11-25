import Accelerate
import AVFoundation
import Foundation
import os

let log = Logger(subsystem: "com.guilhermejeske.JeskeLooper", category: "audio")

/// Runs `work` on the main queue, in order with other main-queue blocks.
func onMain(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(work) }
}

/// Small lock-protected box, used for state shared with the tap thread.
final class Locked<State>: @unchecked Sendable {
    private var state: State
    private let lock = NSLock()

    init(_ state: State) { self.state = state }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

public enum LooperError: LocalizedError, Equatable {
    case deviceSelection(String)
    case noInputChannels(String)
    case noOutputChannels(String)
    case unsupportedFormat(String)
    case engineStart(String, String)
    case inputNotRunning
    case alreadyRecording
    case emptyFile
    case file(String)

    public var errorDescription: String? {
        switch self {
        case .deviceSelection(let device):
            return "Não foi possível usar “\(device)”."
        case .noInputChannels(let device):
            return "“\(device)” não oferece canais de entrada utilizáveis."
        case .noOutputChannels(let device):
            return "“\(device)” não oferece canais de saída utilizáveis."
        case .unsupportedFormat(let what):
            return "Formato de áudio não suportado: \(what)."
        case .engineStart(let device, let detail):
            return "Não foi possível iniciar o áudio em “\(device)” (\(detail)). Confira se o dispositivo está ligado e usando uma taxa de amostragem suportada."
        case .inputNotRunning:
            return "A entrada de áudio não está ativa."
        case .alreadyRecording:
            return "Já existe uma gravação em andamento."
        case .emptyFile:
            return "O arquivo do loop está vazio."
        case .file(let detail):
            return "Problema no arquivo de áudio: \(detail)."
        }
    }

    static func code(_ error: Error) -> String {
        "erro \((error as NSError).code)"
    }
}

/// File format used for new recordings: WAV, linear PCM 24-bit, keeping the device's sample rate and stereo.
public enum LoopAudioFormat {
    public static let fileExtension = "wav"

    public static func fileSettings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Float32, deinterleaved, 1 or 2 channels.
    public static func processingFormat(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)
    }

    /// Human-readable description, e.g. "WAV PCM 24 bits".
    public static func describe(_ format: AVAudioFormat, fileExtension ext: String) -> String {
        let container = ext.uppercased() == "AIF" ? "AIFF" : ext.uppercased()
        let bits = format.settings[AVLinearPCMBitDepthKey] as? Int ?? 0
        let isFloat = format.settings[AVLinearPCMIsFloatKey] as? Bool ?? false
        guard bits > 0 else { return container }
        return "\(container) PCM \(bits) bits" + (isFloat ? " float" : "")
    }
}

public enum LooperFormat {
    /// "0:07,4" (m:ss,d) or "1:02:03" for very long loops.
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00,0" }
        let tenths = Int((seconds * 10).rounded(.down))
        let total = tenths / 10
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d,%d", m, s, tenths % 10)
    }

    /// "44,1 kHz", "48 kHz".
    public static func sampleRate(_ rate: Double) -> String {
        let k = rate / 1000
        if k == k.rounded() { return "\(Int(k)) kHz" }
        return String(format: "%.1f kHz", k).replacingOccurrences(of: ".", with: ",")
    }
}

extension AVAudioPCMBuffer {
    /// Largest absolute sample over all channels.
    func peakMagnitude() -> Float {
        guard let data = floatChannelData, frameLength > 0 else { return 0 }
        var peak: Float = 0
        for c in 0..<Int(format.channelCount) {
            var m: Float = 0
            vDSP_maxmgv(data[c], 1, &m, vDSP_Length(frameLength))
            peak = max(peak, m)
        }
        return peak
    }
}
