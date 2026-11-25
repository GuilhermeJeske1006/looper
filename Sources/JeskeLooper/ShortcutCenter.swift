import AppKit
import Carbon.HIToolbox
import Combine
import LooperCore
import SwiftUI

/// Mac keyboard shortcuts: single keys while the looper window is in front, and optionally
/// ⌃⌥ + the same key from any app.
@MainActor
final class ShortcutCenter: ObservableObject {
    @Published var settings: ShortcutSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save(to: .standard)
            updateGlobalHotKeys()
        }
    }
    /// Action whose key is being recorded in Ajustes.
    @Published var recording: LooperCommand?
    @Published var recordingMessage: String?
    /// ⌃⌥ combinations another app already owns.
    @Published private(set) var globalProblems: [String] = []

    weak var mainWindow: NSWindow?
    private weak var model: LooperController?
    private var monitor: Any?
    private let hotKeys = GlobalHotKeys()

    init() {
        settings = ShortcutSettings.load(from: .standard)
    }

    func attach(_ model: LooperController) {
        self.model = model
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
        hotKeys.onPress = { [weak self] action in
            MainActor.assumeIsolated { self?.run(action) }
        }
        updateGlobalHotKeys()
    }

    func label(for command: LooperCommand) -> String? {
        settings.shortcut(for: command)?.label
    }

    func toggleRecording(_ command: LooperCommand) {
        recording = recording == command ? nil : command
        recordingMessage = nil
    }

    func restoreDefaults() {
        recording = nil
        settings = .standard
    }

    // MARK: Key handling

    /// True when the key was used by the looper.
    private func handle(_ event: NSEvent) -> Bool {
        if let command = recording {
            capture(event, for: command)
            return true
        }
        // Only in the main window, never while a dialog, the help popover or a text field is active.
        guard let window = mainWindow, NSApp.keyWindow === window, window.attachedSheet == nil,
              !(window.firstResponder is NSTextView) else { return false }
        return route(event)
    }

    /// Runs the action bound to `event`. True when the key belongs to the looper.
    func route(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return false }
        let immediate = flags.contains(.shift)
        let modifiers = Self.modifiers(flags)

        if settings.numberKeysPlayLoops, modifiers.isEmpty, let number = KeyCodes.loopNumber(forKeyCode: event.keyCode) {
            if !event.isARepeat { model.playLoop(number: number, immediate: immediate) }
            return true
        }
        guard let command = settings.command(keyCode: event.keyCode, modifiers: modifiers) else { return false }
        if !event.isARepeat || command.repeatsWhileHeld { model.perform(command, immediate: immediate) }
        return true
    }

    private func capture(_ event: NSEvent, for command: LooperCommand) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = flags.intersection([.command, .shift, .option, .control]).isEmpty
        if event.keyCode == KeyCodes.delete && plain {
            settings.set(nil, for: command)
            recording = nil
            recordingMessage = nil
            return
        }
        if flags.contains(.command) || flags.contains(.shift) {
            recordingMessage = "Use uma tecla sem ⌘ e sem ⇧ (⌃ e ⌥ podem)."
            return
        }
        let shortcut = KeyShortcut(keyCode: event.keyCode, modifiers: Self.modifiers(flags), key: Self.keyName(event))
        if let problem = settings.problem(with: shortcut) {
            recordingMessage = problem
            return
        }
        settings.set(shortcut, for: command)
        recording = nil
        recordingMessage = nil
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
        var modifiers: ShortcutModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        return modifiers
    }

    static func keyName(_ event: NSEvent) -> String {
        if let name = KeyCodes.name(for: event.keyCode) { return name }
        let characters = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return characters.isEmpty ? "Tecla \(event.keyCode)" : characters.uppercased()
    }

    // MARK: Global (⌃⌥ + key)

    private func updateGlobalHotKeys() {
        hotKeys.unregisterAll()
        globalProblems = []
        guard settings.worksInBackground, model != nil else { return }
        var entries: [GlobalHotKeys.Entry] = []
        for command in LooperCommand.allCases {
            guard let shortcut = settings.shortcut(for: command) else { continue }
            entries.append(GlobalHotKeys.Entry(keyCode: shortcut.keyCode,
                                               carbonModifiers: UInt32(controlKey | optionKey),
                                               action: .command(command),
                                               label: "⌃⌥" + shortcut.key))
        }
        if settings.numberKeysPlayLoops {
            for number in 1...9 {
                guard let code = KeyCodes.topRowKeyCode(forLoopNumber: number) else { continue }
                entries.append(GlobalHotKeys.Entry(keyCode: code, carbonModifiers: UInt32(controlKey | optionKey),
                                                   action: .loop(number), label: "⌃⌥\(number)"))
            }
        }
        globalProblems = hotKeys.register(entries)
    }

    /// Validation: tries to register every ⌃⌥ combination and releases them again.
    func probeGlobalHotKeys() -> (registered: Int, failures: [String]) {
        let wasEnabled = settings.worksInBackground
        settings.worksInBackground = true
        let failures = globalProblems
        let registered = (LooperCommand.allCases.count + (settings.numberKeysPlayLoops ? 9 : 0)) - failures.count
        settings.worksInBackground = wasEnabled
        return (registered, failures)
    }

    private func run(_ action: GlobalHotKeys.Action) {
        switch action {
        case .command(let command): model?.perform(command)
        case .loop(let number): model?.playLoop(number: number)
        }
    }
}

/// System-wide hot keys through Carbon `RegisterEventHotKey` (no Accessibility permission needed).
final class GlobalHotKeys {
    enum Action {
        case command(LooperCommand)
        case loop(Int)
    }

    struct Entry {
        let keyCode: UInt16
        let carbonModifiers: UInt32
        let action: Action
        let label: String
    }

    /// Called on the main thread.
    var onPress: ((Action) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: Action] = [:]
    private var handler: EventHandlerRef?

    /// Returns the labels that could not be registered (already used by another app).
    func register(_ entries: [Entry]) -> [String] {
        installHandler()
        var failures: [String] = []
        for (index, entry) in entries.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(entry.keyCode), entry.carbonModifiers,
                                             EventHotKeyID(signature: OSType(0x4A4C_4F50), id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id] = entry.action
            } else {
                failures.append(entry.label)
            }
        }
        return failures
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr else { return status }
            Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue().fire(hotKey.id)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func fire(_ id: UInt32) {
        guard let action = actions[id] else { return }
        DispatchQueue.main.async { self.onPress?(action) }
    }
}

/// Reports the NSWindow hosting a SwiftUI view.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
