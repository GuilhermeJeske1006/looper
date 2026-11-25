import AVFoundation
import Foundation

public enum LoopPlaybackStrategy: String, Sendable {
    /// Whole loop in RAM.
    case memory
    /// Long loop read from disk in small blocks, always a little ahead of playback.
    case streaming
}

/// How a newly requested loop takes over from the one that is playing.
public enum LoopTransition: Sendable, Equatable {
    /// Stop whatever plays and start this loop from silence.
    case restart
    /// Start exactly when the current loop finishes its turn (no gap, short crossfade).
    case atCycleEnd
    /// Start as soon as possible with a short crossfade (no gap).
    case immediate
}

public struct PlaybackInfo: Sendable, Equatable {
    public let token: Int
    public let strategy: LoopPlaybackStrategy
    public let seamRampApplied: Bool
    public let fileSampleRate: Double
    public let outputSampleRate: Double
    /// What was actually done (a request becomes `.restart` when nothing was playing).
    public let transition: LoopTransition
}

public struct PlaybackPosition: Sendable, Equatable {
    /// Token of the loop being heard.
    public let token: Int
    /// 0…1 inside the current turn.
    public let progress: Double
    public let cycleSeconds: Double
}

/// Short raised-cosine fades at the loop seam, applied only when the last and first samples
/// don't join smoothly. Duration is unchanged; the source file is never modified.
public struct EdgeRamp: Equatable, Sendable {
    public let length: Int

    public init(length: Int) { self.length = length }

    public static func defaultLength(sampleRate: Double) -> Int {
        max(16, Int((sampleRate * 0.003).rounded()))
    }

    /// True when the jump across the seam is clearly larger than the waveform's own slope.
    public static func seamIsDiscontinuous(penultimate: Float, last: Float, first: Float, second: Float) -> Bool {
        let jump = abs(first - last)
        let slope = max(abs(last - penultimate), abs(second - first))
        return jump > max(0.002, 4 * slope)
    }

    public static func detect(in file: AVAudioFile) -> EdgeRamp? {
        let total = file.length
        let length = defaultLength(sampleRate: file.processingFormat.sampleRate)
        guard total > AVAudioFramePosition(length * 4),
              let head = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2),
              let tail = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2) else { return nil }
        defer { file.framePosition = 0 }
        do {
            file.framePosition = 0
            try file.read(into: head, frameCount: 2)
            file.framePosition = total - 2
            try file.read(into: tail, frameCount: 2)
        } catch {
            return nil
        }
        guard head.frameLength == 2, tail.frameLength == 2,
              let h = head.floatChannelData, let t = tail.floatChannelData else { return nil }
        for c in 0..<Int(file.processingFormat.channelCount)
        where seamIsDiscontinuous(penultimate: t[c][0], last: t[c][1], first: h[c][0], second: h[c][1]) {
            return EdgeRamp(length: length)
        }
        return nil
    }

    public static func detect(in buffer: AVAudioPCMBuffer) -> EdgeRamp? {
        let total = Int(buffer.frameLength)
        let length = defaultLength(sampleRate: buffer.format.sampleRate)
        guard total > length * 4, let d = buffer.floatChannelData else { return nil }
        for c in 0..<Int(buffer.format.channelCount)
        where seamIsDiscontinuous(penultimate: d[c][total - 2], last: d[c][total - 1], first: d[c][0], second: d[c][1]) {
            return EdgeRamp(length: length)
        }
        return nil
    }

    public func gain(atFrame frame: Int64, totalFrames: Int64) -> Float {
        let l = Int64(length)
        if frame < l { return Self.curve(Float(frame) / Float(l)) }
        if frame >= totalFrames - l { return Self.curve(Float(totalFrames - 1 - frame) / Float(l)) }
        return 1
    }

    static func curve(_ x: Float) -> Float { 0.5 - 0.5 * cos(Float.pi * x) }

    /// `buffer` holds frames [startFrame, startFrame + frameLength) of a loop of `totalFrames`.
    public func apply(to buffer: AVAudioPCMBuffer, startFrame: Int64, totalFrames: Int64) {
        guard let data = buffer.floatChannelData else { return }
        apply(to: data, channelCount: Int(buffer.format.channelCount), offset: 0, count: Int(buffer.frameLength),
              startFrame: startFrame, totalFrames: totalFrames)
    }

    /// Frames [startFrame, startFrame + count) of the loop live at `offset` in `channels`.
    func apply(to channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, offset: Int, count: Int,
               startFrame: Int64, totalFrames: Int64) {
        guard totalFrames > Int64(length * 2) else { return }
        let span = startFrame..<(startFrame + Int64(count))
        let l = Int64(length)
        for region in [span.clamped(to: 0..<l), span.clamped(to: (totalFrames - l)..<totalFrames)] {
            for frame in region {
                let g = gain(atFrame: frame, totalFrames: totalFrames)
                let i = offset + Int(frame - startFrame)
                for c in 0..<channelCount { channels[c][i] *= g }
            }
        }
    }
}

// MARK: - Loop sources (already at the output sample rate)

/// One loop, read sequentially in the output sample rate. Confined to the player queue once playing.
class LoopSource {
    let token: Int
    let length: Int64
    let ramp: EdgeRamp?
    let strategy: LoopPlaybackStrategy
    let fileSampleRate: Double
    var position: Int64 = 0

    init(token: Int, length: Int64, ramp: EdgeRamp?, strategy: LoopPlaybackStrategy, fileSampleRate: Double) {
        self.token = token
        self.length = length
        self.ramp = ramp
        self.strategy = strategy
        self.fileSampleRate = fileSampleRate
    }

    /// Copies up to `count` frames of the current turn into `out` at `offset`, without wrapping.
    final func read(into out: AVAudioPCMBuffer, offset: Int, count: Int) throws -> Int {
        let n = Int(min(Int64(count), length - position))
        guard n > 0, let d = out.floatChannelData else { return 0 }
        let channels = Int(out.format.channelCount)
        try fetch(into: d, channels: channels, offset: offset, count: n)
        ramp?.apply(to: d, channelCount: channels, offset: offset, count: n, startFrame: position, totalFrames: length)
        position += Int64(n)
        return n
    }

    /// Like `read`, but carries on from the start when the turn ends.
    final func readWrapping(into out: AVAudioPCMBuffer, offset: Int, count: Int) throws {
        var done = 0
        while done < count {
            if position >= length { position = 0 }
            let n = try read(into: out, offset: offset + done, count: count - done)
            guard n > 0 else { throw LooperError.file("leitura vazia") }
            done += n
        }
        if position >= length { position = 0 }
    }

    func fetch(into out: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, offset: Int, count: Int) throws {}
}

final class MemoryLoopSource: LoopSource {
    private let buffer: AVAudioPCMBuffer

    init(token: Int, buffer: AVAudioPCMBuffer, ramp: EdgeRamp?, fileSampleRate: Double) {
        self.buffer = buffer
        super.init(token: token, length: Int64(buffer.frameLength), ramp: ramp, strategy: .memory, fileSampleRate: fileSampleRate)
    }

    override func fetch(into out: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, offset: Int, count: Int) throws {
        guard let src = buffer.floatChannelData else { return }
        let srcChannels = Int(buffer.format.channelCount)
        for c in 0..<channels {
            (out[c] + offset).update(from: src[min(c, srcChannels - 1)] + Int(position), count: count)
        }
    }
}

final class FileLoopSource: LoopSource {
    private let file: AVAudioFile
    private let scratch: AVAudioPCMBuffer

    init(token: Int, file: AVAudioFile, chunkFrames: AVAudioFrameCount, ramp: EdgeRamp?, fileSampleRate: Double) throws {
        guard let scratch = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: max(chunkFrames, 4096)) else {
            throw LooperError.file("memória insuficiente para o loop")
        }
        self.file = file
        self.scratch = scratch
        super.init(token: token, length: file.length, ramp: ramp, strategy: .streaming, fileSampleRate: fileSampleRate)
    }

    override func fetch(into out: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, offset: Int, count: Int) throws {
        let srcChannels = Int(file.processingFormat.channelCount)
        var done = 0
        while done < count {
            let n = min(count - done, Int(scratch.frameCapacity))
            file.framePosition = position + Int64(done)
            try file.read(into: scratch, frameCount: AVAudioFrameCount(n))
            let got = Int(scratch.frameLength)
            guard got > 0, let src = scratch.floatChannelData else { throw LooperError.file("fim inesperado do arquivo") }
            for c in 0..<channels {
                (out[c] + offset + done).update(from: src[min(c, srcChannels - 1)], count: got)
            }
            done += got
        }
    }
}

enum LoopSourceLoader {
    static func load(url: URL, token: Int, outputRate: Double, memoryLimitSeconds: Double, chunkFrames: AVAudioFrameCount,
                     ramps: Bool, cacheDirectory: URL) throws -> LoopSource {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw LooperError.file("não foi possível abrir “\(url.lastPathComponent)”")
        }
        guard file.length > 0 else { throw LooperError.emptyFile }
        let format = file.processingFormat
        guard format.channelCount <= 2 else { throw LooperError.unsupportedFormat("arquivo com mais de 2 canais") }
        let sameRate = abs(format.sampleRate - outputRate) < 0.5

        if Double(file.length) / format.sampleRate <= memoryLimitSeconds {
            guard let all = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw LooperError.file("memória insuficiente para o loop")
            }
            try file.read(into: all)
            let buffer = sameRate ? all : try Resampler.resample(all, to: outputRate)
            guard buffer.frameLength > 0 else { throw LooperError.emptyFile }
            return MemoryLoopSource(token: token, buffer: buffer, ramp: ramps ? EdgeRamp.detect(in: buffer) : nil,
                                    fileSampleRate: format.sampleRate)
        }

        var stream = file
        if !sameRate {
            let converted = try Resampler.convertedCopy(of: url, rate: outputRate, in: cacheDirectory)
            stream = try AVAudioFile(forReading: converted, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        return try FileLoopSource(token: token, file: stream, chunkFrames: chunkFrames,
                                  ramp: ramps ? EdgeRamp.detect(in: stream) : nil, fileSampleRate: format.sampleRate)
    }
}

/// Sample-rate conversion for loops whose rate differs from the output device.
enum Resampler {
    static func resample(_ input: AVAudioPCMBuffer, to rate: Double) throws -> AVAudioPCMBuffer {
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                            channels: input.format.channelCount, interleaved: false),
              let converter = AVAudioConverter(from: input.format, to: outFormat) else {
            throw LooperError.unsupportedFormat("conversão de taxa de amostragem")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let expected = AVAudioFrameCount((Double(input.frameLength) * rate / input.format.sampleRate).rounded())
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: expected + 8192),
              let chunk = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192) else {
            throw LooperError.file("memória insuficiente para o loop")
        }
        var supplied = false
        while true {
            var error: NSError?
            let status = converter.convert(to: chunk, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error { throw LooperError.unsupportedFormat("conversão de taxa de amostragem") }
            let room = Int(output.frameCapacity - output.frameLength)
            let n = min(Int(chunk.frameLength), room)
            if n > 0, let src = chunk.floatChannelData, let dst = output.floatChannelData {
                for c in 0..<Int(outFormat.channelCount) {
                    (dst[c] + Int(output.frameLength)).update(from: src[c], count: n)
                }
                output.frameLength += AVAudioFrameCount(n)
            }
            if status == .endOfStream || chunk.frameLength == 0 { break }
        }
        output.frameLength = min(output.frameLength, expected)
        return output
    }

    /// Long loops are converted once into a cache file and then streamed from it.
    static func convertedCopy(of url: URL, rate: Double, in directory: URL) throws -> URL {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let stamp = Int((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let target = directory.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(stamp)-\(size)-\(Int(rate)).caf")
        if fm.fileExists(atPath: target.path) { return target }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let inFormat = input.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                            channels: inFormat.channelCount, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 32768),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 32768) else {
            throw LooperError.unsupportedFormat("conversão de taxa de amostragem")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let temp = directory.appendingPathComponent(".\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: inFormat.channelCount,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            let output = try AVAudioFile(forWriting: temp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            var ended = false
            while true {
                var error: NSError?
                let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
                    if !ended {
                        do { try input.read(into: inBuffer, frameCount: inBuffer.frameCapacity) } catch { inBuffer.frameLength = 0 }
                        if inBuffer.frameLength > 0 {
                            inputStatus.pointee = .haveData
                            return inBuffer
                        }
                        ended = true
                    }
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if status == .error { throw LooperError.unsupportedFormat("conversão de taxa de amostragem") }
                if outBuffer.frameLength > 0 { try output.write(from: outBuffer) }
                if status == .endOfStream { break }
            }
            if #available(macOS 15.0, *) { output.close() }
        }
        try fm.moveItem(at: temp, to: target)
        return target
    }
}

// MARK: - Player

/// Output-only AVAudioEngine on the chosen device.
///
/// A single player node is fed with short blocks rendered on `queue`, a few hundred
/// milliseconds ahead of what is heard. Because every block is generated here, a loop
/// repeats and hands over to the next loop sample-accurately, with no silence in between.
public final class LoopPlayer: @unchecked Sendable {
    public enum SeamRamps: Sendable { case automatic, never }

    /// Called on the main thread when the engine stopped on its own (format change or device lost).
    public var onInterruption: (@MainActor () -> Void)?
    /// Called on the main thread when the loop with this token starts being heard after a transition.
    public var onAudibleLoopChanged: (@MainActor (Int) -> Void)?
    /// Loops up to this length are held in memory; longer ones are streamed from disk.
    public var memoryLimitSeconds: Double = 45
    /// Size of each rendered block. Lookahead = blockSeconds × blockCount.
    public var blockSeconds: Double = 0.05
    public var blockCount = 4
    /// Crossfade between two different loops.
    public var crossfadeSeconds: Double = 0.01
    public var seamRamps: SeamRamps = .automatic
    public var cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.guilhermejeske.JeskeLooper/Convertidos", isDirectory: true)
    /// Validation hook: receives what the player node renders.
    public var debugTap: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?

    private let queue = DispatchQueue(label: "com.guilhermejeske.JeskeLooper.playback", qos: .userInteractive)
    private let loadQueue = DispatchQueue(label: "com.guilhermejeske.JeskeLooper.playback.load", qos: .userInitiated)

    // queue-confined
    private var engine: AVAudioEngine?
    private var engineDevice: AudioDevice?
    private var timelineFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var observer: NSObjectProtocol?
    private var playerNode: AVAudioPlayerNode?
    private var blocks: [AVAudioPCMBuffer] = []
    private var scratch: AVAudioPCMBuffer?
    private var current: LoopSource?
    private var pending: (source: LoopSource, transition: LoopTransition)?
    private var fadeOut: (source: LoopSource, done: Int, total: Int)?
    private var fadeIn: (done: Int, total: Int)?
    private var rendered: Int64 = 0
    private var generation = 0
    /// Requests are applied in order; `stop` invalidates every request still loading and
    /// `cancelQueued` the ones meant to take over from the current loop.
    private var stopEpoch = 0
    private var queueEpoch = 0
    private var volume: Float = 0.8

    private struct Clock {
        var node: AVAudioPlayerNode?
        var rate: Double = 0
        var turns: [(frame: Int64, token: Int, length: Int64)] = []
    }
    private let clock = Locked(Clock())

    public init() {}

    public func setVolume(_ value: Float) {
        queue.async {
            self.volume = value
            self.engine?.mainMixerNode.outputVolume = value
        }
    }

    /// Plays `url` on `device`. With `.atCycleEnd` or `.immediate` and a loop already playing on the
    /// same device, the new loop takes over without any gap; otherwise it starts from silence.
    public func play(url: URL, token: Int, on device: AudioDevice, transition: LoopTransition,
                     completion: @escaping @MainActor (Result<PlaybackInfo, Error>) -> Void) {
        queue.async {
            let epochs = (self.stopEpoch, self.queueEpoch)
            let handOver = transition != .restart && self.isPlaying(on: device)
            let rate: Double
            do {
                if !handOver && !(self.engine?.isRunning == true && self.engineDevice?.objectID == device.objectID) {
                    try self.prepareEngine(for: device)
                }
                guard let format = self.timelineFormat else { throw LooperError.noOutputChannels(device.name) }
                rate = format.sampleRate
            } catch {
                onMain { completion(.failure(error)) }
                return
            }
            let memoryLimit = self.memoryLimitSeconds
            let chunk = AVAudioFrameCount(self.blockSeconds * rate)
            let ramps = self.seamRamps == .automatic
            let cache = self.cacheDirectory
            self.loadQueue.async {
                let loaded = Result {
                    try LoopSourceLoader.load(url: url, token: token, outputRate: rate, memoryLimitSeconds: memoryLimit,
                                              chunkFrames: chunk, ramps: ramps, cacheDirectory: cache)
                }
                self.queue.async {
                    // Dropped by a later stop, or by a cancel when this was meant to take over.
                    guard epochs.0 == self.stopEpoch, transition == .restart || epochs.1 == self.queueEpoch else { return }
                    let result = loaded.flatMap { source in
                        Result { try self.apply(source, transition: transition, device: device) }
                    }
                    if case .failure = result, self.playerNode == nil { self.teardownEngine() }
                    onMain { completion(result) }
                }
            }
        }
    }

    /// Drops a loop waiting for the end of the current turn.
    public func cancelQueued() {
        queue.async {
            self.queueEpoch += 1
            self.pending = nil
        }
    }

    public func stop(completion: (@MainActor () -> Void)? = nil) {
        queue.async {
            self.stopEpoch += 1
            self.stopNode(fade: true)
            self.teardownEngine()
            if let completion { onMain(completion) }
        }
    }

    /// What is being heard right now. Safe to call from any thread.
    public func position() -> PlaybackPosition? {
        clock.withLock { state in
            guard let node = state.node, state.rate > 0,
                  let nodeTime = node.lastRenderTime, let time = node.playerTime(forNodeTime: nodeTime) else { return nil }
            let played = time.sampleTime
            guard let turn = state.turns.last(where: { $0.frame <= played }) ?? state.turns.first, turn.length > 0 else { return nil }
            let into = max(0, played - turn.frame) % turn.length
            return PlaybackPosition(token: turn.token, progress: Double(into) / Double(turn.length),
                                    cycleSeconds: Double(turn.length) / state.rate)
        }
    }

    /// Number of player nodes attached right now (validation).
    public func attachedPlayerCount() -> Int {
        queue.sync { engine?.attachedNodes.filter { $0 is AVAudioPlayerNode }.count ?? 0 }
    }

    // MARK: Transitions (queue)

    private func isPlaying(on device: AudioDevice) -> Bool {
        playerNode != nil && current != nil && engine?.isRunning == true && engineDevice?.objectID == device.objectID
    }

    private func apply(_ source: LoopSource, transition: LoopTransition, device: AudioDevice) throws -> PlaybackInfo {
        var applied = transition
        if transition != .restart && isPlaying(on: device) {
            pending = (source, transition)
        } else {
            applied = .restart
            if engine == nil || engineDevice?.objectID != device.objectID || timelineFormat == nil {
                try prepareEngine(for: device)
            }
            try startFresh(source)
        }
        let rate = timelineFormat?.sampleRate ?? 0
        log.notice("Loop \(source.token) (\(source.strategy.rawValue, privacy: .public)) on \(device.name, privacy: .public): \(String(describing: applied), privacy: .public)")
        return PlaybackInfo(token: source.token, strategy: source.strategy, seamRampApplied: source.ramp != nil,
                            fileSampleRate: source.fileSampleRate, outputSampleRate: outputFormat?.sampleRate ?? rate,
                            transition: applied)
    }

    private func startFresh(_ source: LoopSource) throws {
        guard let engine, let format = timelineFormat else { throw LooperError.deviceSelection("saída") }
        stopNode(fade: true)
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        if let debugTap {
            node.installTap(onBus: 0, bufferSize: 4096, format: nil) { debugTap($0, $1) }
        }
        generation += 1
        let gen = generation
        source.position = 0
        current = source
        pending = nil
        fadeOut = nil
        fadeIn = nil
        rendered = 0
        clock.withLock { $0 = Clock(node: node, rate: format.sampleRate, turns: [(0, source.token, source.length)]) }

        let frames = AVAudioFrameCount(max(256, (blockSeconds * format.sampleRate).rounded()))
        if blocks.count != blockCount || blocks.first?.frameCapacity != frames || blocks.first?.format != format {
            blocks = (0..<blockCount).compactMap { _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) }
            scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
            guard blocks.count == blockCount, scratch != nil else { throw LooperError.file("memória insuficiente") }
        }
        playerNode = node
        for block in blocks {
            render(into: block)
            schedule(block, on: node, generation: gen)
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            stopNode(fade: false)
            throw LooperError.engineStart(engineDevice?.name ?? "saída", LooperError.code(error))
        }
        node.volume = 0
        node.play()
        ramp(node, to: 1, duration: 0.012)
    }

    private func schedule(_ block: AVAudioPCMBuffer, on node: AVAudioPlayerNode, generation gen: Int) {
        node.scheduleBuffer(block, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.generation == gen, self.playerNode === node else { return }
                self.render(into: block)
                self.schedule(block, on: node, generation: gen)
            }
        }
    }

    // MARK: Rendering (queue)

    /// Fills `block` with the next frames of the timeline: the current loop, wrapping at the end
    /// of each turn, and handing over to a pending loop where requested.
    private func render(into block: AVAudioPCMBuffer) {
        let n = Int(block.frameCapacity)
        block.frameLength = AVAudioFrameCount(n)
        guard let out = block.floatChannelData else { return }
        let channels = Int(block.format.channelCount)
        for c in 0..<channels { out[c].update(repeating: 0, count: n) }

        if let next = pending, next.transition == .immediate {
            pending = nil
            handOver(to: next.source, at: rendered)
        }
        var i = 0
        do {
            while i < n, let source = current {
                let got = try source.read(into: block, offset: i, count: n - i)
                if got > 0 {
                    applyFadeIn(out, channels: channels, offset: i, count: got)
                    try mixFadeOut(into: out, channels: channels, offset: i, count: got)
                    i += got
                }
                if source.position >= source.length {
                    source.position = 0
                    if let next = pending, next.transition == .atCycleEnd {
                        pending = nil
                        handOver(to: next.source, at: rendered + Int64(i))
                    } else {
                        markTurn(source, at: rendered + Int64(i), announce: false)
                    }
                } else if got == 0 {
                    break
                }
            }
        } catch {
            log.error("Playback read failed: \(error.localizedDescription, privacy: .public)")
            current = nil
            onMain { [weak self] in self?.onInterruption?() }
        }
        rendered += Int64(n)
    }

    private func handOver(to source: LoopSource, at frame: Int64) {
        let total = max(1, Int((crossfadeSeconds * (timelineFormat?.sampleRate ?? 44_100)).rounded()))
        if let previous = current { fadeOut = (previous, 0, total) }
        source.position = 0
        current = source
        fadeIn = (0, total)
        markTurn(source, at: frame, announce: true)
    }

    private func applyFadeIn(_ out: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, offset: Int, count: Int) {
        guard let fade = fadeIn else { return }
        let m = min(count, fade.total - fade.done)
        for k in 0..<m {
            let g = sin(Float.pi / 2 * Float(fade.done + k) / Float(fade.total))
            for c in 0..<channels { out[c][offset + k] *= g }
        }
        fadeIn = fade.done + m >= fade.total ? nil : (fade.done + m, fade.total)
    }

    /// The previous loop keeps going under the new one for the length of the crossfade.
    private func mixFadeOut(into out: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, offset: Int, count: Int) throws {
        guard let fade = fadeOut, let scratch, let tmp = scratch.floatChannelData else { return }
        let m = min(count, fade.total - fade.done, Int(scratch.frameCapacity))
        try fade.source.readWrapping(into: scratch, offset: 0, count: m)
        for k in 0..<m {
            let g = cos(Float.pi / 2 * Float(fade.done + k) / Float(fade.total))
            for c in 0..<channels { out[c][offset + k] += tmp[c][k] * g }
        }
        fadeOut = fade.done + m >= fade.total ? nil : (fade.source, fade.done + m, fade.total)
    }

    private func markTurn(_ source: LoopSource, at frame: Int64, announce: Bool) {
        let (node, rate) = clock.withLock { state -> (AVAudioPlayerNode?, Double) in
            state.turns.append((frame, source.token, source.length))
            if state.turns.count > 16 { state.turns.removeFirst(state.turns.count - 16) }
            return (state.node, state.rate)
        }
        guard announce, let node, rate > 0 else { return }
        var played: Int64 = 0
        if let nodeTime = node.lastRenderTime, let time = node.playerTime(forNodeTime: nodeTime) { played = time.sampleTime }
        let token = source.token
        let delay = max(0, Double(frame - played) / rate)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.onAudibleLoopChanged?(token) }
        }
    }

    // MARK: Engine (queue)

    private func prepareEngine(for device: AudioDevice) throws {
        stopNode(fade: true)
        teardownEngine()
        let engine = AVAudioEngine()
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(device.objectID)
        } catch {
            throw LooperError.deviceSelection(device.name)
        }
        let hw = engine.outputNode.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0,
              let output = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channels: min(hw.channelCount, 2)),
              let timeline = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channels: 2) else {
            throw LooperError.noOutputChannels(device.name)
        }
        // The timeline is always stereo at the device rate; the mixer folds it to mono if needed.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: output)
        engine.mainMixerNode.outputVolume = volume
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: nil) { [weak self, weak engine] _ in
            guard let self, let engine else { return }
            self.queue.async { self.configurationChanged(engine) }
        }
        self.engine = engine
        engineDevice = device
        outputFormat = output
        timelineFormat = timeline
    }

    private func configurationChanged(_ changed: AVAudioEngine) {
        guard changed === engine, let device = engineDevice else { return }
        let hw = changed.outputNode.outputFormat(forBus: 0)
        if let format = outputFormat, AudioHardware.isAlive(device.objectID),
           hw.sampleRate == format.sampleRate, hw.channelCount >= format.channelCount {
            // Same device, same format: AVAudioEngine sometimes stops itself on its own.
            if changed.isRunning { return }
            guard let source = current else {
                teardownEngine()
                return
            }
            do {
                try prepareEngine(for: device)
                try startFresh(source)
                log.notice("Playback restarted after a configuration change")
                return
            } catch {
                log.error("Playback restart failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        log.notice("Output configuration changed; stopping playback engine")
        teardownEngine()
        onMain { [weak self] in self?.onInterruption?() }
    }

    private func stopNode(fade: Bool) {
        guard let node = playerNode else { return }
        generation += 1
        playerNode = nil
        clock.withLock { $0 = Clock() }
        if fade, engine?.isRunning == true, node.isPlaying {
            ramp(node, to: 0, duration: 0.025)
        }
        node.stop()
        if debugTap != nil { node.removeTap(onBus: 0) }
        engine?.detach(node)
        current = nil
        pending = nil
        fadeOut = nil
        fadeIn = nil
    }

    private func teardownEngine() {
        stopNode(fade: false)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.stop()
        engine = nil
        engineDevice = nil
        outputFormat = nil
        timelineFormat = nil
        blocks = []
        scratch = nil
    }

    /// Short gain ramp on the player's mixer input to avoid clicks on start/stop.
    private func ramp(_ node: AVAudioPlayerNode, to target: Float, duration: Double) {
        let steps = 8
        let start = node.volume
        let pause = useconds_t(duration / Double(steps) * 1_000_000)
        for i in 1...steps {
            node.volume = start + (target - start) * Float(i) / Float(steps)
            usleep(pause)
        }
    }
}
