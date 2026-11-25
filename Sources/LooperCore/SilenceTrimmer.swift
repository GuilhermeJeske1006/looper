import Accelerate
import AVFoundation
import Foundation

/// Finds and removes the silence before the first note and after the last one.
public enum SilenceTrimmer {
    /// -60 dBFS. The CK sends digital silence (0) when nothing is played.
    public static let threshold: Float = 0.001

    public struct Plan: Equatable, Sendable {
        /// Kept frames: [start, end).
        public let start: Int64
        public let end: Int64
        public let total: Int64
        public let sampleRate: Double

        public var removedStart: Double { Double(start) / sampleRate }
        public var removedEnd: Double { Double(total - end) / sampleRate }
        public var keptDuration: Double { Double(end - start) / sampleRate }
        /// Less than 10 ms on each side is not worth rewriting the file.
        public var changesNothing: Bool { removedStart < 0.01 && removedEnd < 0.01 }
    }

    /// Returns nil when the whole file is below the threshold.
    public static func plan(for url: URL, leading: Bool, trailing: Bool, threshold: Float = threshold,
                            preRoll: Double = 0.01, postRoll: Double = 0.03) throws -> Plan? {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let total = file.length
        let channels = Int(format.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw LooperError.file("memória insuficiente")
        }
        func loud(_ d: UnsafePointer<UnsafeMutablePointer<Float>>, _ i: Int) -> Bool {
            for c in 0..<channels where abs(d[c][i]) > threshold { return true }
            return false
        }

        var first: Int64?
        var last: Int64?
        var position: Int64 = 0
        while position < total {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(65_536, total - position)))
            let n = Int(buffer.frameLength)
            guard n > 0, let d = buffer.floatChannelData else { break }
            var peak: Float = 0
            for c in 0..<channels {
                var m: Float = 0
                vDSP_maxmgv(d[c], 1, &m, vDSP_Length(n))
                peak = max(peak, m)
            }
            if peak > threshold {
                if first == nil, let i = (0..<n).first(where: { loud(d, $0) }) { first = position + Int64(i) }
                if let i = (0..<n).reversed().first(where: { loud(d, $0) }) { last = position + Int64(i) }
            }
            position += Int64(n)
        }
        guard let first, let last else { return nil }
        let rate = format.sampleRate
        let start = leading ? max(0, first - Int64(preRoll * rate)) : 0
        let end = trailing ? min(total, last + 1 + Int64(postRoll * rate)) : total
        return Plan(start: start, end: end, total: total, sampleRate: rate)
    }

    /// Copies frames [plan.start, plan.end) into a new WAV file with the same rate and channels.
    public static func write(_ plan: Plan, from source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw LooperError.file("memória insuficiente")
        }
        let writer = try LoopFileWriter(url: destination, format: format)
        input.framePosition = plan.start
        var remaining = plan.end - plan.start
        while remaining > 0 {
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(65_536, remaining)))
            guard buffer.frameLength > 0 else { break }
            writer.append(buffer)
            remaining -= Int64(buffer.frameLength)
        }
        writer.close()
        if let error = writer.error {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
