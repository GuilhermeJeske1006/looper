import Accelerate
import AVFoundation
import Foundation

/// Thread-safe peak meter fed by the input tap and polled by the UI.
public final class InputLevel: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var left: Float = 0
        public var right: Float = 0
        public var channels: Int = 0
    }

    private let state = Locked(Snapshot())

    public init() {}

    func accumulate(left: Float, right: Float, channels: Int) {
        state.withLock {
            $0.left = max($0.left, left)
            $0.right = max($0.right, right)
            $0.channels = channels
        }
    }

    /// Peaks since the previous call.
    public func consume() -> Snapshot {
        state.withLock { s in
            let snapshot = s
            s.left = 0
            s.right = 0
            return snapshot
        }
    }

    func reset() { state.withLock { $0 = Snapshot() } }
}

public struct InputFormatInfo: Equatable, Sendable {
    public let sampleRate: Double
    public let deviceChannels: Int
    public let recordedChannels: Int
}

public struct RecordingResult: Sendable {
    public let url: URL?
    public let frames: Int64
    public let sampleRate: Double
    public let channels: Int
    public let peak: Float
    public let errorDescription: String?

    public var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
}

/// Which frames of a captured buffer fall inside the recording window [start, end).
public enum RecordingWindowMath {
    public static func frames(bufferStart: Double, frameCount: Int, sampleRate: Double,
                              windowStart: Double, windowEnd: Double?) -> (range: Range<Int>, reachedEnd: Bool) {
        func clamp(_ v: Double) -> Int { Int(min(max(v, 0), Double(frameCount))) }
        let first = clamp(((windowStart - bufferStart) * sampleRate).rounded(.up))
        var last = frameCount
        var reachedEnd = false
        if let windowEnd {
            last = clamp(((windowEnd - bufferStart) * sampleRate).rounded(.up))
            reachedEnd = bufferStart + Double(frameCount) / sampleRate >= windowEnd
        }
        return (first..<max(first, last), reachedEnd)
    }
}

/// Writes float buffers to a WAV file. Only used from one serial queue.
public final class LoopFileWriter {
    public let id: Int
    public let url: URL
    public let format: AVAudioFormat
    private var file: AVAudioFile?
    public private(set) var framesWritten: Int64 = 0
    public private(set) var peak: Float = 0
    public private(set) var error: Error?

    public init(id: Int = 0, url: URL, format: AVAudioFormat) throws {
        self.id = id
        self.url = url
        self.format = format
        file = try AVAudioFile(forWriting: url,
                               settings: LoopAudioFormat.fileSettings(sampleRate: format.sampleRate, channels: format.channelCount),
                               commonFormat: .pcmFormatFloat32,
                               interleaved: false)
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        guard error == nil, let file, buffer.frameLength > 0 else { return }
        do {
            try file.write(from: buffer)
            framesWritten += Int64(buffer.frameLength)
            peak = max(peak, buffer.peakMagnitude())
        } catch {
            self.error = error
        }
    }

    /// Finalizes the header. The file is complete and readable after this returns.
    public func close() {
        if #available(macOS 15.0, *) { file?.close() }
        file = nil
    }
}

/// Input-only AVAudioEngine on the chosen device. Never routes input to an output.
///
/// The tap runs on an AVAudioEngine worker thread (not the real-time I/O thread). It only
/// measures peaks and copies the frames that fall inside the recording window; disk writes
/// happen on `writerQueue`.
public final class InputEngine: @unchecked Sendable {
    public let level = InputLevel()
    /// Called on the main thread when the engine stopped on its own (format change or device lost).
    public var onInterruption: (@MainActor () -> Void)?

    private let control = DispatchQueue(label: "com.guilhermejeske.JeskeLooper.input", qos: .userInitiated)
    private let writerQueue = DispatchQueue(label: "com.guilhermejeske.JeskeLooper.writer", qos: .userInitiated)

    // control queue
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var hardwareFormat: AVAudioFormat?
    private var deviceID: AudioDeviceID?

    // shared with the tap thread
    private struct Window {
        var id: Int
        var start: Double
        var end: Double?
        var finished = false
    }
    private struct TapState {
        var sampleRate: Double = 0
        var recordFormat: AVAudioFormat?
        var window: Window?
    }
    private let tapState = Locked(TapState())

    // writer queue
    private var writer: LoopFileWriter?
    private var finishHandler: ((RecordingResult) -> Void)?

    // caller (main) thread
    private var windowCounter = 0
    private var currentURL: URL?

    public init() {}

    // MARK: Engine lifecycle

    public func start(device: AudioDevice, completion: @escaping @MainActor (Result<InputFormatInfo, Error>) -> Void) {
        control.async {
            let result = Result { try self.startEngine(device) }
            onMain { completion(result) }
        }
    }

    public func stop() {
        control.async { self.teardown() }
    }

    private func startEngine(_ device: AudioDevice) throws -> InputFormatInfo {
        teardown()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        do {
            try input.auAudioUnit.setDeviceID(device.objectID)
        } catch {
            throw LooperError.deviceSelection(device.name)
        }
        let hw = input.inputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else { throw LooperError.noInputChannels(device.name) }
        guard hw.commonFormat == .pcmFormatFloat32, !hw.isInterleaved else {
            throw LooperError.unsupportedFormat("entrada de “\(device.name)”")
        }
        let recordChannels = AVAudioChannelCount(min(Int(hw.channelCount), 2))
        guard let recordFormat = LoopAudioFormat.processingFormat(sampleRate: hw.sampleRate, channels: recordChannels) else {
            throw LooperError.unsupportedFormat("entrada de “\(device.name)”")
        }
        tapState.withLock { $0 = TapState(sampleRate: hw.sampleRate, recordFormat: recordFormat, window: nil) }

        input.installTap(onBus: 0, bufferSize: 2048, format: hw) { [weak self] buffer, when in
            self?.process(buffer, when)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapState.withLock { $0.sampleRate = 0 }
            throw LooperError.engineStart(device.name, LooperError.code(error))
        }
        self.engine = engine
        hardwareFormat = hw
        deviceID = device.objectID
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: nil) { [weak self, weak engine] _ in
            guard let self, let engine else { return }
            self.control.async { self.configurationChanged(engine) }
        }
        log.notice("Input started on \(device.name, privacy: .public): \(hw.sampleRate) Hz, \(hw.channelCount) ch")
        return InputFormatInfo(sampleRate: hw.sampleRate, deviceChannels: Int(hw.channelCount), recordedChannels: Int(recordChannels))
    }

    private func configurationChanged(_ changed: AVAudioEngine) {
        guard changed === engine else { return }
        let hw = changed.inputNode.inputFormat(forBus: 0)
        if let old = hardwareFormat, let device = deviceID, AudioHardware.isAlive(device),
           hw.sampleRate == old.sampleRate, hw.channelCount == old.channelCount {
            // Same device, same format: AVAudioEngine sometimes stops itself right after
            // starting. Restart it; the tap stays installed.
            if changed.isRunning { return }
            do {
                try changed.start()
                log.notice("Input engine restarted after a configuration change")
                return
            } catch {
                log.error("Input engine restart failed: \(LooperError.code(error), privacy: .public)")
            }
        }
        log.notice("Input configuration changed; stopping input engine")
        teardown()
        onMain { [weak self] in self?.onInterruption?() }
    }

    private func teardown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        hardwareFormat = nil
        deviceID = nil
        tapState.withLock { state in
            state.sampleRate = 0
            state.window?.finished = true
        }
        level.reset()
    }

    // MARK: Tap (AVAudioEngine worker thread)

    private func process(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let src = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        var left: Float = 0, right: Float = 0
        vDSP_maxmgv(src[0], 1, &left, vDSP_Length(frames))
        if channels > 1 { vDSP_maxmgv(src[1], 1, &right, vDSP_Length(frames)) } else { right = left }
        level.accumulate(left: left, right: right, channels: min(channels, 2))

        let sampleRate = buffer.format.sampleRate
        let bufferStart = when.isHostTimeValid
            ? AVAudioTime.seconds(forHostTime: when.hostTime)
            : AVAudioTime.seconds(forHostTime: mach_absolute_time()) - Double(frames) / sampleRate

        typealias Decision = (id: Int, range: Range<Int>, finished: Bool, format: AVAudioFormat)
        let decision: Decision? = tapState.withLock { state in
            guard var window = state.window, !window.finished, let format = state.recordFormat else { return nil }
            let r = RecordingWindowMath.frames(bufferStart: bufferStart, frameCount: frames, sampleRate: sampleRate,
                                               windowStart: window.start, windowEnd: window.end)
            if r.reachedEnd {
                window.finished = true
                state.window = window
            }
            return (window.id, r.range, r.reachedEnd, format)
        }
        guard let decision else { return }

        if !decision.range.isEmpty, let copy = Self.copyFrames(buffer, range: decision.range, format: decision.format) {
            writerQueue.async { [weak self] in
                guard let writer = self?.writer, writer.id == decision.id else { return }
                writer.append(copy)
            }
        }
        if decision.finished {
            writerQueue.async { [weak self] in self?.completeWriter(id: decision.id) }
        }
    }

    private static func copyFrames(_ src: AVAudioPCMBuffer, range: Range<Int>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)),
              let s = src.floatChannelData, let d = out.floatChannelData else { return nil }
        let srcChannels = Int(src.format.channelCount)
        for c in 0..<Int(format.channelCount) {
            d[c].update(from: s[min(c, srcChannels - 1)] + range.lowerBound, count: range.count)
        }
        out.frameLength = AVAudioFrameCount(range.count)
        return out
    }

    // MARK: Recording (called from the main thread)

    /// Starts writing every frame captured at or after `hostTime`.
    public func beginRecording(to url: URL, hostTime: UInt64 = mach_absolute_time()) throws {
        let (sampleRate, format, busy) = tapState.withLock { ($0.sampleRate, $0.recordFormat, $0.window != nil) }
        guard sampleRate > 0, let format else { throw LooperError.inputNotRunning }
        guard !busy else { throw LooperError.alreadyRecording }
        windowCounter += 1
        let id = windowCounter
        try writerQueue.sync {
            finishHandler = nil
            writer = try LoopFileWriter(id: id, url: url, format: format)
        }
        currentURL = url
        let start = AVAudioTime.seconds(forHostTime: hostTime)
        tapState.withLock { $0.window = Window(id: id, start: start) }
    }

    /// Ends the recording at `hostTime`. With `waitForTail`, waits for the tap to deliver the
    /// frames up to that instant (at most 1 s); otherwise finalizes with what was already captured.
    public func finishRecording(hostTime: UInt64 = mach_absolute_time(), waitForTail: Bool,
                                completion: @escaping @MainActor (RecordingResult) -> Void) {
        let end = AVAudioTime.seconds(forHostTime: hostTime)
        let url = currentURL
        currentURL = nil
        writerQueue.async {
            self.finishHandler = { result in onMain { completion(result) } }
        }
        let state: (id: Int, finished: Bool)? = tapState.withLock { s in
            guard var window = s.window else { return nil }
            if window.end == nil { window.end = end }
            if !waitForTail || s.sampleRate == 0 { window.finished = true }
            s.window = window
            return (window.id, window.finished)
        }
        guard let state else {
            writerQueue.async {
                let handler = self.finishHandler
                self.finishHandler = nil
                handler?(RecordingResult(url: url, frames: 0, sampleRate: 0, channels: 0, peak: 0, errorDescription: nil))
            }
            return
        }
        if state.finished {
            writerQueue.async { self.completeWriter(id: state.id) }
        } else {
            writerQueue.asyncAfter(deadline: .now() + 1.0) {
                self.tapState.withLock { s in
                    if s.window?.id == state.id { s.window?.finished = true }
                }
                self.completeWriter(id: state.id)
            }
        }
    }

    // writer queue
    private func completeWriter(id: Int) {
        guard let writer, writer.id == id else { return }
        self.writer = nil
        writer.close()
        tapState.withLock { s in
            if s.window?.id == id { s.window = nil }
        }
        let result = RecordingResult(url: writer.url,
                                     frames: writer.framesWritten,
                                     sampleRate: writer.format.sampleRate,
                                     channels: Int(writer.format.channelCount),
                                     peak: writer.peak,
                                     errorDescription: writer.error?.localizedDescription)
        let handler = finishHandler
        finishHandler = nil
        handler?(result)
    }
}
