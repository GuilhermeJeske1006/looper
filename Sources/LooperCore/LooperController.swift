import AVFoundation
import Combine
import Foundation

/// A device choice remembered between sessions.
public struct SavedDevice: Codable, Equatable, Sendable {
    public var uid: String
    public var name: String
    public var manufacturer: String

    public init(_ device: AudioDevice) {
        uid = device.uid
        name = device.name
        manufacturer = device.manufacturer
    }

    public init(uid: String, name: String, manufacturer: String) {
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
    }
}

public enum DeviceStatus: Equatable, Sendable {
    case notSelected
    case starting
    case ready(String)
    case disconnected
    case permissionNeeded
    case problem(String)
}

public struct Banner: Identifiable, Equatable {
    public enum Kind: Sendable { case info, warning, error }
    public enum Action: Sendable { case openMicrophoneSettings }

    public let id = UUID()
    public let kind: Kind
    public let text: String
    public let action: Action?
}

/// What happens when another loop is chosen while one is repeating.
public enum LoopSwitchMode: String, CaseIterable, Codable, Sendable {
    /// The new loop starts exactly when the current one finishes its turn.
    case atCycleEnd
    /// The new loop starts right away, with a short crossfade.
    case immediate
}

/// All app state and the rules between recording and playback. Views only call into this.
@MainActor
public final class LooperController: ObservableObject {
    public enum Mode: Equatable {
        case idle
        case recording(since: Date)
        case saving
        case playing(UUID)
    }

    @Published public private(set) var mode: Mode = .idle
    @Published public private(set) var inputDevices: [AudioDevice] = []
    @Published public private(set) var outputDevices: [AudioDevice] = []
    @Published public private(set) var savedInput: SavedDevice?
    @Published public private(set) var savedOutput: SavedDevice?
    @Published public private(set) var inputStatus: DeviceStatus = .notSelected
    @Published public private(set) var outputStatus: DeviceStatus = .notSelected
    @Published public private(set) var loops: [LoopItem] = []
    @Published public var selectedLoopID: UUID?
    @Published public private(set) var volume: Float
    @Published public var banner: Banner?
    /// Loop waiting for the end of the current turn.
    @Published public private(set) var queuedLoopID: UUID?
    /// Loop whose silence is being trimmed.
    @Published public private(set) var processingLoopID: UUID?
    @Published public var switchMode: LoopSwitchMode {
        didSet { defaults.set(switchMode.rawValue, forKey: Keys.switchMode) }
    }
    @Published public var trimLeadingSilence: Bool {
        didSet { defaults.set(trimLeadingSilence, forKey: Keys.trimLeading) }
    }
    @Published public var trimTrailingSilence: Bool {
        didSet { defaults.set(trimTrailingSilence, forKey: Keys.trimTrailing) }
    }

    public let store: LoopStore
    public let input = InputEngine()
    public let player = LoopPlayer()
    public var level: InputLevel { input.level }
    public private(set) var lastPlaybackInfo: PlaybackInfo?
    /// Device the input engine is running on (nil when stopped).
    public private(set) var activeInputDevice: AudioDevice?

    public var maxRecordingSeconds: Double = 30 * 60
    public var minimumRecordingSeconds: Double = 0.2
    /// Below this peak (≈ -94 dBFS) a take is treated as empty.
    public var silenceThreshold: Float = 0.000_02

    private let defaults: UserDefaults
    private var watcher: AudioDeviceWatcher?
    private var playingOutput: AudioDevice?
    private var refreshWork: DispatchWorkItem?
    private var recordingTimer: DispatchSourceTimer?
    private var playToken = 0
    /// Announcements for tokens at or below this are stale (a newer start or a stop happened).
    private var tokenFloor = 0
    private var tokenLoops: [Int: UUID] = [:]
    private var inputToken = 0
    private var requestingPermission = false
    private var inputRestarts: [Date] = []
    private var outputRestarts: [Date] = []
    private var terminationHandler: (() -> Void)?
    private var started = false

    private enum Keys {
        static let input = "audio.input"
        static let output = "audio.output"
        static let volume = "playback.volume"
        static let switchMode = "playback.switchMode"
        static let trimLeading = "recording.trimLeadingSilence"
        static let trimTrailing = "recording.trimTrailingSilence"
    }

    public init(store: LoopStore = LoopStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        volume = defaults.object(forKey: Keys.volume) == nil ? 0.8 : Float(defaults.double(forKey: Keys.volume))
        savedInput = Self.decode(defaults.data(forKey: Keys.input))
        savedOutput = Self.decode(defaults.data(forKey: Keys.output))
        switchMode = defaults.string(forKey: Keys.switchMode).flatMap(LoopSwitchMode.init(rawValue:)) ?? .atCycleEnd
        trimLeadingSilence = defaults.object(forKey: Keys.trimLeading) as? Bool ?? true
        trimTrailingSilence = defaults.object(forKey: Keys.trimTrailing) as? Bool ?? true
    }

    // MARK: Derived state

    public var isRecording: Bool { if case .recording = mode { return true } else { return false } }
    public var isSaving: Bool { mode == .saving }
    public var playingLoopID: UUID? { if case .playing(let id) = mode { return id } else { return nil } }
    public var isPlaying: Bool { playingLoopID != nil }
    public var isBusy: Bool { isRecording || isSaving }
    public var canChangeDevices: Bool { !isBusy }
    public var canEditLoops: Bool { !isBusy && processingLoopID == nil }
    public var inputIsReady: Bool { if case .ready = inputStatus { return true } else { return false } }
    public var canRecord: Bool { !isBusy && inputIsReady && activeInputDevice != nil }
    public var resolvedOutput: AudioDevice? { savedOutput.flatMap { Self.resolve($0, in: outputDevices) } }
    public var canPlay: Bool { !isBusy && resolvedOutput != nil }

    /// Same UID, or — if the keyboard moved to another USB port and got a new UID — the one
    /// device with the same name and maker. Never falls back to some other device.
    public static func resolve(_ saved: SavedDevice, in devices: [AudioDevice]) -> AudioDevice? {
        if let exact = devices.first(where: { $0.uid == saved.uid }) { return exact }
        let sameModel = devices.filter { $0.name == saved.name && $0.manufacturer == saved.manufacturer }
        return sameModel.count == 1 ? sameModel[0] : nil
    }

    // MARK: Startup

    public func start() {
        guard !started else { return }
        started = true
        do {
            try store.load()
        } catch {
            show(.error, "Não foi possível abrir a pasta dos loops: \(error.localizedDescription)")
        }
        loops = store.loops
        if let note = store.loadNotes.first { show(.info, note) }

        input.onInterruption = { [weak self] in self?.inputInterrupted() }
        player.onInterruption = { [weak self] in self?.outputInterrupted() }
        player.onAudibleLoopChanged = { [weak self] token in self?.loopBecameAudible(token) }
        player.setVolume(volume)
        watcher = AudioDeviceWatcher(queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleDeviceRefresh() }
        }
        enumerateDevices()
        applyFirstLaunchChoices()
        reconcileInput()
        reconcileOutput()
    }

    /// First launch only: preselect the CK if it is connected. Without a CK the input stays
    /// empty — the built-in microphone is never chosen on the user's behalf.
    private func applyFirstLaunchChoices() {
        var changed = false
        if savedInput == nil,
           let ck = inputDevices.first(where: \.isYamahaCK) ?? inputDevices.first(where: \.isYamaha) {
            savedInput = SavedDevice(ck)
            changed = true
        }
        if savedOutput == nil {
            if let ck = outputDevices.first(where: \.isYamahaCK) ?? outputDevices.first(where: \.isYamaha) {
                savedOutput = SavedDevice(ck)
                changed = true
            } else if let id = AudioHardware.defaultOutputDeviceID(),
                      let device = outputDevices.first(where: { $0.objectID == id }) {
                savedOutput = SavedDevice(device)
                changed = true
            }
        }
        if changed { persistDevices() }
    }

    public func shutdown() {
        stopRecordingTimer()
        watcher = nil
        player.stop()
        input.stop()
    }

    public var needsGracefulTermination: Bool { isBusy }

    /// Finishes and saves a recording in progress before quitting.
    public func prepareForTermination(_ done: @escaping () -> Void) {
        if isBusy {
            terminationHandler = { [weak self] in
                self?.shutdown()
                done()
            }
            if isRecording { finishRecording(waitForTail: true, autoplay: false, note: nil) }
        } else {
            shutdown()
            done()
        }
    }

    /// The user may have granted access in System Settings meanwhile.
    public func recheckPermission() {
        guard inputStatus == .permissionNeeded, MicrophonePermission.current == .authorized else { return }
        if banner?.action == .openMicrophoneSettings { banner = nil }
        reconcileInput()
    }

    // MARK: Devices

    public func selectInput(uid: String?) {
        guard canChangeDevices else { return }
        guard let uid, !uid.isEmpty else {
            savedInput = nil
            persistDevices()
            stopInputEngine()
            inputStatus = .notSelected
            return
        }
        guard let device = inputDevices.first(where: { $0.uid == uid }) else { return }
        if savedInput?.uid == uid, activeInputDevice?.objectID == device.objectID { return }
        savedInput = SavedDevice(device)
        persistDevices()
        stopInputEngine()
        inputRestarts.removeAll()
        startInput(device)
    }

    public func selectOutput(uid: String?) {
        guard canChangeDevices else { return }
        guard let uid, !uid.isEmpty else {
            if isPlaying { stopPlaybackInternal() }
            savedOutput = nil
            persistDevices()
            outputStatus = .notSelected
            return
        }
        guard let device = outputDevices.first(where: { $0.uid == uid }) else { return }
        if savedOutput?.uid == uid { return }
        savedOutput = SavedDevice(device)
        persistDevices()
        outputStatus = .ready(Self.describeOutput(device))
        outputRestarts.removeAll()
        restartCurrentLoop()
    }

    public func refreshDevices() {
        enumerateDevices()
        reconcileInput()
        reconcileOutput()
    }

    private func scheduleDeviceRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func enumerateDevices() {
        let all = AudioHardware.devices()
        let inputs = all.filter(\.hasInput)
        let outputs = all.filter(\.hasOutput)
        if inputs != inputDevices { inputDevices = inputs }
        if outputs != outputDevices { outputDevices = outputs }
    }

    private func reconcileInput() {
        guard let saved = savedInput else {
            if activeInputDevice != nil { stopInputEngine() }
            inputStatus = .notSelected
            return
        }
        let resolved = Self.resolve(saved, in: inputDevices)
        if let resolved, resolved.uid != saved.uid {
            savedInput = SavedDevice(resolved)
            persistDevices()
        }
        switch (activeInputDevice, resolved) {
        case (nil, nil):
            if inputStatus == .starting || inputIsReady {
                show(.warning, "Entrada “\(saved.name)” desconectada.")
            }
            inputStatus = .disconnected
        case (let active?, nil):
            inputLost(active)
        case (nil, let device?):
            startInput(device)
        case (let active?, let device?):
            if active.objectID != device.objectID {
                stopInputEngine()
                startInput(device)
            }
        }
    }

    private func reconcileOutput() {
        guard let saved = savedOutput else {
            if isPlaying { stopPlaybackInternal() }
            outputStatus = .notSelected
            return
        }
        if let device = Self.resolve(saved, in: outputDevices) {
            if device.uid != saved.uid {
                savedOutput = SavedDevice(device)
                persistDevices()
            }
            outputStatus = .ready(Self.describeOutput(device))
            if isPlaying, let current = playingOutput, current.objectID != device.objectID {
                restartCurrentLoop()
            }
        } else {
            let wasPlaying = isPlaying
            if wasPlaying {
                stopPlaybackInternal()
                show(.warning, "A saída “\(saved.name)” foi desconectada. A repetição parou.")
            } else if outputStatus != .disconnected && outputStatus != .notSelected {
                show(.warning, "Saída “\(saved.name)” desconectada.")
            }
            outputStatus = .disconnected
        }
    }

    private func startInput(_ device: AudioDevice) {
        switch MicrophonePermission.current {
        case .authorized:
            break
        case .notDetermined:
            inputStatus = .permissionNeeded
            guard !requestingPermission else { return }
            requestingPermission = true
            MicrophonePermission.request { [weak self] granted in
                guard let self else { return }
                self.requestingPermission = false
                if granted {
                    self.reconcileInput()
                } else {
                    self.showPermissionBanner()
                }
            }
            return
        case .denied, .restricted:
            if inputStatus != .permissionNeeded { showPermissionBanner() }
            inputStatus = .permissionNeeded
            return
        }

        inputToken += 1
        let token = inputToken
        activeInputDevice = device
        inputStatus = .starting
        input.start(device: device) { [weak self] result in
            guard let self, token == self.inputToken else { return }
            switch result {
            case .success(let info):
                self.inputStatus = .ready(Self.describe(info))
            case .failure(let error):
                self.activeInputDevice = nil
                self.inputStatus = .problem(error.localizedDescription)
            }
        }
    }

    private func stopInputEngine() {
        inputToken += 1
        activeInputDevice = nil
        input.stop()
    }

    private func inputLost(_ device: AudioDevice) {
        if isRecording {
            finishRecording(waitForTail: false, autoplay: false,
                            note: "A entrada “\(device.name)” foi desconectada e a gravação foi interrompida.")
        } else {
            show(.warning, "Entrada “\(device.name)” desconectada.")
        }
        stopInputEngine()
        inputStatus = .disconnected
    }

    private func inputInterrupted() {
        guard let device = activeInputDevice else { return }
        inputToken += 1
        activeInputDevice = nil
        if isRecording {
            finishRecording(waitForTail: false, autoplay: false,
                            note: "A entrada “\(device.name)” mudou de configuração ou foi desconectada; a gravação foi encerrada.")
        }
        let now = Date()
        inputRestarts = inputRestarts.filter { now.timeIntervalSince($0) < 15 } + [now]
        guard inputRestarts.count <= 3 else {
            inputStatus = .problem("A entrada “\(device.name)” parou de responder. Escolha-a novamente.")
            return
        }
        inputStatus = .starting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
    }

    private func outputInterrupted() {
        guard let id = playingLoopID else { return }
        playingOutput = nil
        let now = Date()
        outputRestarts = outputRestarts.filter { now.timeIntervalSince($0) < 15 } + [now]
        let alive = AudioHardware.devices().filter { $0.hasOutput && AudioHardware.isAlive($0.objectID) }
        if let saved = savedOutput, Self.resolve(saved, in: alive) != nil, outputRestarts.count <= 3 {
            // Same device, new format (e.g. sample rate changed): restart the same loop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.playingLoopID == id else { return }
                    self.enumerateDevices()
                    self.restartCurrentLoop()
                }
            }
        } else {
            playToken += 1
            tokenFloor = playToken
            queuedLoopID = nil
            mode = .idle
            show(.warning, "A saída “\(savedOutput?.name ?? "")” foi desconectada. A repetição parou.")
        }
    }

    // MARK: Recording

    public func startRecording() {
        guard canRecord else { return }
        if isPlaying { stopPlaybackInternal() }
        do {
            let url = try store.newRecordingURL()
            try input.beginRecording(to: url)
        } catch {
            show(.error, "Não foi possível começar a gravar. \(error.localizedDescription)")
            return
        }
        banner = nil
        mode = .recording(since: Date())
        startRecordingTimer()
    }

    public func stopRecording() {
        guard isRecording else { return }
        finishRecording(waitForTail: true, autoplay: true, note: nil)
    }

    private func finishRecording(waitForTail: Bool, autoplay: Bool, note: String?) {
        stopRecordingTimer()
        mode = .saving
        input.finishRecording(waitForTail: waitForTail) { [weak self] result in
            self?.recordingFinished(result, autoplay: autoplay, note: note)
        }
    }

    private func recordingFinished(_ result: RecordingResult, autoplay: Bool, note: String?) {
        func withNote(_ text: String) -> String { [note, text].compactMap { $0 }.joined(separator: " ") }
        guard let url = result.url else {
            finishSaving()
            return
        }
        if let error = result.errorDescription {
            discard(url, .error, withNote("A gravação falhou e não foi salva (\(error))."))
            return
        }
        if result.duration < minimumRecordingSeconds {
            discard(url, .info, withNote("A gravação ficou vazia ou curta demais e não foi salva."))
            return
        }
        if result.peak < silenceThreshold {
            discard(url, .warning, withNote("Nenhum som chegou pela entrada, então nada foi salvo. Confira a entrada escolhida e o volume do teclado."))
            return
        }
        let leading = trimLeadingSilence, trailing = trimTrailingSilence
        guard leading || trailing, let trimmedURL = try? store.newRecordingURL() else {
            saveRecording(url, plan: nil, autoplay: autoplay, note: note)
            return
        }
        // Cut the silence before the first note / after the last one off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            var plan: SilenceTrimmer.Plan?
            var finalURL = url
            if let found = try? SilenceTrimmer.plan(for: url, leading: leading, trailing: trailing), !found.changesNothing,
               (try? SilenceTrimmer.write(found, from: url, to: trimmedURL)) != nil {
                try? FileManager.default.removeItem(at: url)
                plan = found
                finalURL = trimmedURL
            }
            onMain { [weak self] in
                self?.saveRecording(finalURL, plan: plan, autoplay: autoplay, note: note)
            }
        }
    }

    private func saveRecording(_ url: URL, plan: SilenceTrimmer.Plan?, autoplay: Bool, note: String?) {
        func withNote(_ text: String) -> String { [note, text].compactMap { $0 }.joined(separator: " ") }
        if let plan, plan.keptDuration < minimumRecordingSeconds {
            discard(url, .info, withNote("Depois de cortar o silêncio, a gravação ficou curta demais e não foi salva."))
            return
        }
        do {
            let item = try store.addRecording(at: url)
            loops = store.loops
            selectedLoopID = item.id
            if let note {
                show(.warning, "\(note) O trecho gravado foi salvo como “\(item.name)”.")
            } else if let plan, plan.removedStart + plan.removedEnd >= 0.1 {
                show(.info, "Silêncio cortado de “\(item.name)”: \(Self.seconds(plan.removedStart)) no início e \(Self.seconds(plan.removedEnd)) no fim.")
            }
            let resume = autoplay && terminationHandler == nil
            finishSaving()
            if resume { play(loopID: item.id) }
        } catch {
            discard(url, .error, withNote("Não foi possível salvar a gravação: \(error.localizedDescription)"))
        }
    }

    private func discard(_ url: URL, _ kind: Banner.Kind, _ message: String) {
        store.discardRecording(at: url)
        show(kind, message)
        finishSaving()
    }

    private func finishSaving() {
        mode = .idle
        if let handler = terminationHandler {
            terminationHandler = nil
            handler()
        }
    }

    private func startRecordingTimer() {
        stopRecordingTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case .recording(let since) = self.mode,
                      Date().timeIntervalSince(since) >= self.maxRecordingSeconds else { return }
                let minutes = Int(self.maxRecordingSeconds / 60)
                self.finishRecording(waitForTail: true, autoplay: true,
                                     note: "A gravação chegou ao limite de \(minutes) minutos.")
            }
        }
        timer.resume()
        recordingTimer = timer
    }

    private func stopRecordingTimer() {
        recordingTimer?.cancel()
        recordingTimer = nil
    }

    // MARK: Playback

    /// Repeats `loopID`. If another loop is repeating, the new one takes over without a gap:
    /// at the end of the current turn (default) or right away (`immediate` or the immediate mode).
    /// Choosing the queued loop again switches right away; choosing the current loop cancels the queue.
    public func play(loopID: UUID, immediate: Bool = false) {
        guard !isBusy, processingLoopID != loopID, let item = loops.first(where: { $0.id == loopID }) else { return }
        selectedLoopID = loopID
        guard let current = playingLoopID else {
            requestPlay(item, transition: .restart)
            return
        }
        if current == loopID {
            if queuedLoopID != nil { cancelQueue() }
            return
        }
        let now = immediate || switchMode == .immediate || queuedLoopID == loopID
        requestPlay(item, transition: now ? .immediate : .atCycleEnd)
    }

    public func cancelQueue() {
        guard queuedLoopID != nil else { return }
        queuedLoopID = nil
        playToken += 1
        player.cancelQueued()
    }

    /// Starts the current loop again from its beginning (new output device, format change…).
    private func restartCurrentLoop() {
        guard let id = playingLoopID, let item = loops.first(where: { $0.id == id }) else { return }
        queuedLoopID = nil
        requestPlay(item, transition: .restart)
    }

    private func requestPlay(_ item: LoopItem, transition: LoopTransition) {
        guard let saved = savedOutput else {
            show(.warning, "Escolha uma saída de áudio para repetir o loop.")
            return
        }
        guard let device = Self.resolve(saved, in: outputDevices) else {
            show(.warning, "A saída “\(saved.name)” não está conectada.")
            return
        }
        guard item.channels <= 2 else {
            show(.warning, "“\(item.name)” tem mais de 2 canais e não pode ser repetido.")
            return
        }
        playToken += 1
        let token = playToken
        tokenLoops[token] = item.id
        if tokenLoops.count > 64 { tokenLoops = tokenLoops.filter { $0.key > token - 32 } }
        switch transition {
        case .restart, .immediate:
            tokenFloor = token - 1
            queuedLoopID = nil
            mode = .playing(item.id)
            playingOutput = device
        case .atCycleEnd:
            queuedLoopID = item.id
        }
        player.play(url: store.url(for: item), token: token, on: device, transition: transition) { [weak self] result in
            guard let self else { return }
            if case .success(let info) = result, info.transition == .restart, transition != .restart, token > self.tokenFloor {
                // Nothing was playing any more, so the loop started right away instead of waiting.
                self.tokenFloor = token - 1
                if self.queuedLoopID == item.id { self.queuedLoopID = nil }
                self.mode = .playing(item.id)
                self.playingOutput = device
            }
            guard token == self.playToken else { return }
            switch result {
            case .success(let info):
                self.lastPlaybackInfo = info
            case .failure(let error):
                self.queuedLoopID = nil
                self.syncWithPlayer()
                self.show(.error, "Não foi possível repetir “\(item.name)” em “\(device.name)”. \(error.localizedDescription)")
            }
        }
    }

    /// After a failed request, show whatever the player is really doing.
    private func syncWithPlayer() {
        if let position = player.position(), let id = tokenLoops[position.token], loops.contains(where: { $0.id == id }) {
            mode = .playing(id)
        } else if isPlaying {
            mode = .idle
            playingOutput = nil
        }
    }

    private func loopBecameAudible(_ token: Int) {
        guard token > tokenFloor, isPlaying, let id = tokenLoops[token] else { return }
        tokenFloor = token - 1
        if queuedLoopID == id { queuedLoopID = nil }
        if playingLoopID != id { mode = .playing(id) }
    }

    public func stopPlayback() {
        if queuedLoopID != nil && !isPlaying { queuedLoopID = nil }
        guard isPlaying else { return }
        stopPlaybackInternal()
    }

    private func stopPlaybackInternal() {
        playToken += 1
        tokenFloor = playToken
        queuedLoopID = nil
        player.stop()
        mode = .idle
        playingOutput = nil
    }

    // MARK: Keyboard commands

    public func perform(_ command: LooperCommand, immediate: Bool = false) {
        switch command {
        case .toggleRecording:
            if isRecording {
                stopRecording()
            } else if canRecord {
                startRecording()
            } else if !isBusy {
                explainWhyRecordingIsUnavailable()
            }
        case .playSelected:
            guard let id = selectedLoopID ?? loops.first?.id else { return }
            play(loopID: id, immediate: immediate)
        case .stopPlayback:
            stopPlayback()
        case .selectPrevious:
            moveSelection(by: -1)
        case .selectNext:
            moveSelection(by: 1)
        case .volumeDown:
            setVolume(((volume - 0.05) * 20).rounded() / 20)
        case .volumeUp:
            setVolume(((volume + 0.05) * 20).rounded() / 20)
        }
    }

    /// Loop number 1…9 as shown in the list.
    public func playLoop(number: Int, immediate: Bool = false) {
        guard number >= 1, number <= loops.count else { return }
        play(loopID: loops[number - 1].id, immediate: immediate)
    }

    private func moveSelection(by step: Int) {
        guard !loops.isEmpty else { return }
        guard let id = selectedLoopID, let index = loops.firstIndex(where: { $0.id == id }) else {
            selectedLoopID = step > 0 ? loops.first?.id : loops.last?.id
            return
        }
        selectedLoopID = loops[min(max(index + step, 0), loops.count - 1)].id
    }

    private func explainWhyRecordingIsUnavailable() {
        switch inputStatus {
        case .notSelected: show(.info, "Escolha uma entrada de áudio para gravar.")
        case .disconnected: show(.warning, "A entrada “\(savedInput?.name ?? "")” está desconectada.")
        case .permissionNeeded: showPermissionBanner()
        case .problem(let message): show(.warning, message)
        case .starting, .ready: break
        }
    }

    public func setVolume(_ value: Float) {
        let v = min(max(value, 0), 1)
        volume = v
        defaults.set(Double(v), forKey: Keys.volume)
        player.setVolume(v)
    }

    // MARK: Loops

    public func rename(loopID: UUID, to name: String) {
        guard canEditLoops else { return }
        do {
            try store.rename(id: loopID, to: name)
            loops = store.loops
        } catch {
            show(.error, "Não foi possível renomear. \(error.localizedDescription)")
        }
    }

    public func delete(loopID: UUID) {
        guard canEditLoops else { return }
        if playingLoopID == loopID { stopPlaybackInternal() }
        if queuedLoopID == loopID { cancelQueue() }
        do {
            try store.delete(id: loopID)
            loops = store.loops
            if selectedLoopID == loopID { selectedLoopID = nil }
        } catch {
            show(.error, "Não foi possível excluir. \(error.localizedDescription)")
        }
    }

    /// Cuts the silence before the first note and after the last one of a saved loop.
    public func trimSilence(loopID: UUID) {
        guard canEditLoops, let item = loops.first(where: { $0.id == loopID }) else { return }
        let wasPlaying = playingLoopID == loopID
        if wasPlaying { stopPlaybackInternal() }
        if queuedLoopID == loopID { cancelQueue() }
        let source = store.url(for: item)
        let temp: URL
        do { temp = try store.newRecordingURL() } catch {
            show(.error, "Não foi possível cortar o silêncio. \(error.localizedDescription)")
            return
        }
        processingLoopID = loopID
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { () -> SilenceTrimmer.Plan? in
                guard let plan = try SilenceTrimmer.plan(for: source, leading: true, trailing: true), !plan.changesNothing else {
                    return nil
                }
                try SilenceTrimmer.write(plan, from: source, to: temp)
                return plan
            }
            onMain { [weak self] in
                self?.trimFinished(item, temp: temp, outcome: outcome, resume: wasPlaying)
            }
        }
    }

    private func trimFinished(_ item: LoopItem, temp: URL, outcome: Result<SilenceTrimmer.Plan?, Error>, resume: Bool) {
        processingLoopID = nil
        switch outcome {
        case .success(let plan?):
            do {
                let updated = try store.replaceAudio(id: item.id, with: temp)
                loops = store.loops
                show(.info, "Silêncio cortado de “\(updated.name)”: \(Self.seconds(plan.removedStart)) no início e \(Self.seconds(plan.removedEnd)) no fim. Agora: \(LooperFormat.duration(updated.duration)).")
            } catch {
                store.discardRecording(at: temp)
                show(.error, "Não foi possível cortar o silêncio. \(error.localizedDescription)")
            }
        case .success(nil):
            store.discardRecording(at: temp)
            show(.info, "“\(item.name)” não tem silêncio nas bordas para cortar.")
        case .failure(let error):
            store.discardRecording(at: temp)
            show(.error, "Não foi possível cortar o silêncio. \(error.localizedDescription)")
        }
        if resume { play(loopID: item.id) }
    }

    // MARK: Helpers

    static func seconds(_ value: Double) -> String {
        String(format: "%.2f s", value).replacingOccurrences(of: ".", with: ",")
    }

    private func show(_ kind: Banner.Kind, _ text: String, action: Banner.Action? = nil) {
        banner = Banner(kind: kind, text: text, action: action)
    }

    private func showPermissionBanner() {
        show(.warning,
             "O Jeske Looper não tem acesso à entrada de áudio. Permita em Ajustes do Sistema › Privacidade e Segurança › Microfone.",
             action: .openMicrophoneSettings)
    }

    private func persistDevices() {
        let encoder = JSONEncoder()
        if let savedInput, let data = try? encoder.encode(savedInput) {
            defaults.set(data, forKey: Keys.input)
        } else {
            defaults.removeObject(forKey: Keys.input)
        }
        if let savedOutput, let data = try? encoder.encode(savedOutput) {
            defaults.set(data, forKey: Keys.output)
        } else {
            defaults.removeObject(forKey: Keys.output)
        }
    }

    private static func decode(_ data: Data?) -> SavedDevice? {
        data.flatMap { try? JSONDecoder().decode(SavedDevice.self, from: $0) }
    }

    static func describe(_ info: InputFormatInfo) -> String {
        var text = "\(info.recordedChannels == 1 ? "Mono" : "Estéreo") · \(LooperFormat.sampleRate(info.sampleRate))"
        if info.deviceChannels > 2 { text += " · canais 1–2 de \(info.deviceChannels)" }
        return text
    }

    static func describeOutput(_ device: AudioDevice) -> String {
        "\(device.outputChannels == 1 ? "Mono" : "Estéreo") · \(LooperFormat.sampleRate(device.nominalSampleRate))"
    }
}
