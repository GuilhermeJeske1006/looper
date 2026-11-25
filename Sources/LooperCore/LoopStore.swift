import AVFoundation
import Foundation

public struct LoopItem: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var fileName: String
    public var duration: Double
    public var frameCount: Int64
    public var sampleRate: Double
    public var channels: Int
    public var format: String
    public var createdAt: Date
}

public enum LoopStoreError: LocalizedError {
    case emptyName
    case notFound
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "O nome não pode ficar vazio."
        case .notFound: return "Loop não encontrado."
        case .unreadable(let file): return "O arquivo “\(file)” não pôde ser lido."
        }
    }
}

/// Loops on disk plus a small JSON index (`loops.json`) in the same folder.
/// Opening reads only the index and file headers, never the audio itself.
public final class LoopStore {
    public static var defaultDirectory: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        return music.appendingPathComponent("Jeske Looper/Loops", isDirectory: true)
    }

    public let directory: URL
    /// Deleted loops go to the Trash (false only in validation).
    public var useTrash = true
    public private(set) var loops: [LoopItem] = []
    /// Short notes about anything repaired while loading.
    public private(set) var loadNotes: [String] = []

    private struct Index: Codable {
        var version = 1
        var lastNumber: Int?
        var loops: [LoopItem]
    }

    private let fm = FileManager.default
    private var lastNumber = 0
    private var indexURL: URL { directory.appendingPathComponent("loops.json") }
    static let recordingPrefix = ".gravando-"
    static let audioExtensions: Set<String> = ["wav", "caf", "aif", "aiff"]

    public init(directory: URL = LoopStore.defaultDirectory) {
        self.directory = directory
    }

    public func url(for item: LoopItem) -> URL {
        directory.appendingPathComponent(item.fileName)
    }

    // MARK: Loading

    public func load() throws {
        loadNotes = []
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var items: [LoopItem] = []
        var needsSave = false

        if fm.fileExists(atPath: indexURL.path) {
            do {
                let index = try Self.decoder.decode(Index.self, from: Data(contentsOf: indexURL))
                items = index.loops
                lastNumber = index.lastNumber ?? 0
            } catch {
                let backup = directory.appendingPathComponent("loops.json.danificado-\(Int(Date().timeIntervalSince1970))")
                try? fm.moveItem(at: indexURL, to: backup)
                loadNotes.append("A lista de loops estava danificada e foi reconstruída a partir dos arquivos.")
                needsSave = true
            }
        }

        var seenFiles = Set<String>()
        let before = items.count
        items = items.filter { item in
            let key = item.fileName.lowercased()
            guard !seenFiles.contains(key), fm.fileExists(atPath: url(for: item).path) else { return false }
            seenFiles.insert(key)
            return true
        }
        if items.count != before {
            needsSave = true
            let missing = before - items.count
            loadNotes.append(missing == 1
                ? "1 loop sem arquivo de áudio foi removido da lista."
                : "\(missing) loops sem arquivo de áudio foram removidos da lista.")
        }

        let contents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        // Leftovers from an interrupted recording can't be finalized; send them to the Trash.
        for url in contents where url.lastPathComponent.hasPrefix(Self.recordingPrefix) {
            try? remove(url)
        }
        // Audio files dropped into the folder (or written before a crash of the index) are adopted.
        for url in contents where !url.lastPathComponent.hasPrefix(".")
            && Self.audioExtensions.contains(url.pathExtension.lowercased())
            && !seenFiles.contains(url.lastPathComponent.lowercased()) {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            if let item = Self.makeItem(for: url, name: url.deletingPathExtension().lastPathComponent, createdAt: created) {
                items.append(item)
                needsSave = true
            }
        }

        items.sort { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }
        loops = items
        lastNumber = max(lastNumber, highestLoopNumber())
        if needsSave { try save() }
    }

    // MARK: Recording

    /// Hidden file for a recording in progress; becomes a loop through `addRecording`.
    public func newRecordingURL() throws -> URL {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(Self.recordingPrefix)\(UUID().uuidString).\(LoopAudioFormat.fileExtension)")
    }

    public func discardRecording(at url: URL) {
        try? fm.removeItem(at: url)
    }

    /// Moves a finished recording into place as "Loop NNN" and indexes it.
    @discardableResult
    public func addRecording(at tempURL: URL, createdAt: Date = Date()) throws -> LoopItem {
        let (number, name) = nextDefaultName()
        let fileName = uniqueFileName(base: name, ext: LoopAudioFormat.fileExtension)
        let destination = directory.appendingPathComponent(fileName)
        try fm.moveItem(at: tempURL, to: destination)
        // Re-reading the header confirms the file was finalized correctly.
        guard let item = Self.makeItem(for: destination, name: name, createdAt: createdAt) else {
            throw LoopStoreError.unreadable(fileName)
        }
        lastNumber = max(lastNumber, number)
        loops.append(item)
        try save()
        return item
    }

    func nextDefaultName() -> (Int, String) {
        var n = max(lastNumber, highestLoopNumber()) + 1
        while true {
            let name = String(format: "Loop %03d", n)
            let taken = loops.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                || Self.audioExtensions.contains { fm.fileExists(atPath: directory.appendingPathComponent("\(name).\($0)").path) }
            if !taken { return (n, name) }
            n += 1
        }
    }

    private func highestLoopNumber() -> Int {
        let files = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).map { ($0 as NSString).deletingPathExtension }
        let names = loops.map(\.name) + loops.map { ($0.fileName as NSString).deletingPathExtension } + files
        return names.compactMap(Self.loopNumber(in:)).max() ?? 0
    }

    /// 7 for "Loop 007" or "Loop 007 (2)".
    static func loopNumber(in text: String) -> Int? {
        let parts = text.split(separator: " ")
        guard parts.count >= 2, parts[0].lowercased() == "loop", let n = Int(parts[1]), n > 0 else { return nil }
        return n
    }

    // MARK: Rename / delete

    /// Renames the loop and its file; the stable `id` keeps every reference valid.
    @discardableResult
    public func rename(id: UUID, to rawName: String) throws -> LoopItem {
        let name = Self.cleanName(rawName)
        guard !name.isEmpty else { throw LoopStoreError.emptyName }
        guard let idx = loops.firstIndex(where: { $0.id == id }) else { throw LoopStoreError.notFound }
        let previous = loops[idx]
        guard previous.name != name else { return previous }

        let ext = (previous.fileName as NSString).pathExtension
        let newFileName = uniqueFileName(base: Self.fileBase(for: name), ext: ext, ignoring: previous.fileName)
        let oldURL = url(for: previous)
        let newURL = directory.appendingPathComponent(newFileName)
        if newFileName != previous.fileName {
            if newFileName.lowercased() == previous.fileName.lowercased() {
                // Case-only change on a case-insensitive volume.
                let temp = directory.appendingPathComponent(".renomeando-\(UUID().uuidString).\(ext)")
                try fm.moveItem(at: oldURL, to: temp)
                try fm.moveItem(at: temp, to: newURL)
            } else {
                try fm.moveItem(at: oldURL, to: newURL)
            }
        }
        var item = previous
        item.name = name
        item.fileName = newFileName
        loops[idx] = item
        do {
            try save()
        } catch {
            loops[idx] = previous
            if newFileName != previous.fileName { try? fm.moveItem(at: newURL, to: oldURL) }
            throw error
        }
        return item
    }

    /// Puts a new version of the audio in place (same name and id). The previous file goes to the Trash.
    @discardableResult
    public func replaceAudio(id: UUID, with newURL: URL) throws -> LoopItem {
        guard let idx = loops.firstIndex(where: { $0.id == id }) else { throw LoopStoreError.notFound }
        let item = loops[idx]
        let target = url(for: item)
        let ext = (item.fileName as NSString).pathExtension
        let base = (item.fileName as NSString).deletingPathExtension
        let backup = directory.appendingPathComponent(uniqueFileName(base: "\(base) (antes do corte)", ext: ext))
        try fm.moveItem(at: target, to: backup)
        do {
            try fm.moveItem(at: newURL, to: target)
        } catch {
            try? fm.moveItem(at: backup, to: target)
            throw error
        }
        guard let fresh = Self.makeItem(for: target, name: item.name, createdAt: item.createdAt) else {
            try? fm.removeItem(at: target)
            try? fm.moveItem(at: backup, to: target)
            throw LoopStoreError.unreadable(item.fileName)
        }
        var updated = item
        updated.duration = fresh.duration
        updated.frameCount = fresh.frameCount
        updated.sampleRate = fresh.sampleRate
        updated.channels = fresh.channels
        updated.format = fresh.format
        loops[idx] = updated
        try save()
        try? remove(backup)
        return updated
    }

    public func delete(id: UUID) throws {
        guard let idx = loops.firstIndex(where: { $0.id == id }) else { throw LoopStoreError.notFound }
        let fileURL = url(for: loops[idx])
        if fm.fileExists(atPath: fileURL.path) { try remove(fileURL) }
        loops.remove(at: idx)
        try save()
    }

    // MARK: Helpers

    private func remove(_ url: URL) throws {
        if useTrash, (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil { return }
        try fm.removeItem(at: url)
    }

    private func save() throws {
        let data = try Self.encoder.encode(Index(lastNumber: lastNumber, loops: loops))
        try data.write(to: indexURL, options: .atomic)
    }

    private func uniqueFileName(base: String, ext: String, ignoring current: String? = nil) -> String {
        var candidate = "\(base).\(ext)"
        var n = 2
        func taken(_ name: String) -> Bool {
            if let current, name.lowercased() == current.lowercased() { return false }
            return fm.fileExists(atPath: directory.appendingPathComponent(name).path)
                || loops.contains { $0.fileName.lowercased() == name.lowercased() }
        }
        while taken(candidate) {
            candidate = "\(base) (\(n)).\(ext)"
            n += 1
        }
        return candidate
    }

    static func cleanName(_ raw: String) -> String {
        let singleLine = raw.components(separatedBy: .newlines).joined(separator: " ")
        return String(singleLine.trimmingCharacters(in: .whitespaces).prefix(80))
    }

    static func fileBase(for name: String) -> String {
        var base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while base.hasPrefix(".") { base.removeFirst() }
        base = base.trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "Loop" : base
    }

    /// Reads only the header of an audio file.
    static func makeItem(for url: URL, name: String, createdAt: Date) -> LoopItem? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let format = file.fileFormat
        return LoopItem(id: UUID(),
                        name: name,
                        fileName: url.lastPathComponent,
                        duration: Double(file.length) / format.sampleRate,
                        frameCount: file.length,
                        sampleRate: format.sampleRate,
                        channels: Int(format.channelCount),
                        format: LoopAudioFormat.describe(format, fileExtension: url.pathExtension),
                        createdAt: createdAt)
    }

    /// UTC with milliseconds, e.g. "2026-10-20T00:32:14.681Z".
    private static let dateStyle = Date.ISO8601FormatStyle().year().month().day()
        .time(includingFractionalSeconds: true).timeZone(separator: .omitted)

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(LoopStore.dateStyle))
        }
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            // Also accepts the earlier form without the "Z" suffix (UTC).
            let styles = [LoopStore.dateStyle, .iso8601.year().month().day().time(includingFractionalSeconds: true), .iso8601]
            for style in styles {
                if let date = try? Date(text, strategy: style) { return date }
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Data inválida: \(text)"))
        }
        return d
    }()
}
