import Foundation

/// Actions that can be triggered from the Mac keyboard.
public enum LooperCommand: String, CaseIterable, Codable, Identifiable, Sendable {
    case toggleRecording
    case playSelected
    case stopPlayback
    case selectPrevious
    case selectNext
    case volumeDown
    case volumeUp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .toggleRecording: return "Gravar / Parar gravação"
        case .playSelected: return "Repetir o loop selecionado"
        case .stopPlayback: return "Parar a repetição"
        case .selectPrevious: return "Selecionar o loop anterior"
        case .selectNext: return "Selecionar o próximo loop"
        case .volumeDown: return "Diminuir o volume"
        case .volumeUp: return "Aumentar o volume"
        }
    }

    /// Holding the key repeats these.
    public var repeatsWhileHeld: Bool {
        switch self {
        case .selectPrevious, .selectNext, .volumeDown, .volumeUp: return true
        default: return false
        }
    }
}

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = ShortcutModifiers(rawValue: 1)
    public static let option = ShortcutModifiers(rawValue: 2)
}

/// A key on the Mac keyboard (virtual key code, independent of the keyboard layout).
public struct KeyShortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ShortcutModifiers
    /// Printable name of the key itself, e.g. "Espaço", "↩", "A".
    public var key: String

    public init(keyCode: UInt16, modifiers: ShortcutModifiers = [], key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    public var label: String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") + key
    }

    func matches(keyCode code: UInt16, modifiers mods: ShortcutModifiers) -> Bool {
        KeyCodes.normalized(code) == KeyCodes.normalized(keyCode) && mods == modifiers
    }
}

public enum KeyCodes {
    public static let space: UInt16 = 49
    public static let returnKey: UInt16 = 36
    public static let keypadEnter: UInt16 = 76
    public static let escape: UInt16 = 53
    public static let delete: UInt16 = 51
    public static let left: UInt16 = 123
    public static let right: UInt16 = 124
    public static let down: UInt16 = 125
    public static let up: UInt16 = 126

    /// Top-row digits 1…9 and keypad 1…9.
    static let topRowDigits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    static let keypadDigits: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]

    public static func loopNumber(forKeyCode code: UInt16) -> Int? {
        if let i = topRowDigits.firstIndex(of: code) { return i + 1 }
        if let i = keypadDigits.firstIndex(of: code) { return i + 1 }
        return nil
    }

    public static func topRowKeyCode(forLoopNumber n: Int) -> UInt16? {
        (1...9).contains(n) ? topRowDigits[n - 1] : nil
    }

    /// Keypad Enter behaves like Return.
    static func normalized(_ code: UInt16) -> UInt16 { code == keypadEnter ? returnKey : code }

    /// Names for keys that have no printable character.
    public static func name(for code: UInt16) -> String? {
        let names: [UInt16: String] = [
            49: "Espaço", 36: "↩", 76: "Enter", 53: "Esc", 48: "Tab", 51: "⌫", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return names[code]
    }
}

public struct ShortcutSettings: Codable, Equatable, Sendable {
    /// Keyed by `LooperCommand.rawValue`.
    public var bindings: [String: KeyShortcut]
    /// Keys 1…9 repeat loops 1…9.
    public var numberKeysPlayLoops: Bool
    /// Also react to ⌃⌥ + key while another app is in front.
    public var worksInBackground: Bool

    public static let standard = ShortcutSettings(
        bindings: [
            LooperCommand.toggleRecording.rawValue: KeyShortcut(keyCode: KeyCodes.space, key: "Espaço"),
            LooperCommand.playSelected.rawValue: KeyShortcut(keyCode: KeyCodes.returnKey, key: "↩"),
            LooperCommand.stopPlayback.rawValue: KeyShortcut(keyCode: KeyCodes.escape, key: "Esc"),
            LooperCommand.selectPrevious.rawValue: KeyShortcut(keyCode: KeyCodes.up, key: "↑"),
            LooperCommand.selectNext.rawValue: KeyShortcut(keyCode: KeyCodes.down, key: "↓"),
            LooperCommand.volumeDown.rawValue: KeyShortcut(keyCode: KeyCodes.left, key: "←"),
            LooperCommand.volumeUp.rawValue: KeyShortcut(keyCode: KeyCodes.right, key: "→"),
        ],
        numberKeysPlayLoops: true,
        worksInBackground: false)

    public func shortcut(for command: LooperCommand) -> KeyShortcut? {
        bindings[command.rawValue]
    }

    public func command(keyCode: UInt16, modifiers: ShortcutModifiers) -> LooperCommand? {
        LooperCommand.allCases.first { bindings[$0.rawValue]?.matches(keyCode: keyCode, modifiers: modifiers) == true }
    }

    /// Assigns `shortcut` (nil clears) and removes the same key from any other action.
    public mutating func set(_ shortcut: KeyShortcut?, for command: LooperCommand) {
        if let shortcut {
            for other in LooperCommand.allCases where other != command
            && bindings[other.rawValue]?.matches(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) == true {
                bindings[other.rawValue] = nil
            }
        }
        bindings[command.rawValue] = shortcut
    }

    /// Why a key can't be used, or nil when it can.
    public func problem(with shortcut: KeyShortcut) -> String? {
        if numberKeysPlayLoops, shortcut.modifiers.isEmpty, KeyCodes.loopNumber(forKeyCode: shortcut.keyCode) != nil {
            return "As teclas 1 a 9 já repetem os loops."
        }
        return nil
    }

    private static let defaultsKey = "keyboard.shortcuts"

    public static func load(from defaults: UserDefaults) -> ShortcutSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(ShortcutSettings.self, from: data) else { return .standard }
        return settings
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
