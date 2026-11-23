import Foundation

public struct HeadlessSession: Codable, Sendable {
    public var id: String
    public var pid: Int32
    public var state: String
    public var mode: String
    public var target: String
    public var outputPath: String
    public var startedAt: Date
    public var updatedAt: Date
    public var elapsed: Double
    public var result: RecordingResult?
    public var error: String?
    public var code: String?
    public var logFile: String?

    public init(
        id: String,
        pid: Int32,
        state: String,
        mode: String,
        target: String,
        outputPath: String,
        startedAt: Date = Date(),
        elapsed: Double = 0,
        result: RecordingResult? = nil,
        error: String? = nil,
        code: String? = nil,
        logFile: String? = nil
    ) {
        self.id = id
        self.pid = pid
        self.state = state
        self.mode = mode
        self.target = target
        self.outputPath = outputPath
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.elapsed = elapsed
        self.result = result
        self.error = error
        self.code = code
        self.logFile = logFile
    }

    public var isActive: Bool {
        ["starting", "recording", "paused", "finishing", "converting"].contains(state)
    }

    public var isTerminal: Bool {
        ["completed", "failed", "cancelled"].contains(state)
    }
}

public enum SessionStore {
    public static func fileURL(id: String) -> URL {
        AppPaths.sessionsDirectory.appendingPathComponent("\(id).json")
    }

    public static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: AppPaths.sessionsDirectory, withIntermediateDirectories: true)
    }

    public static func write(_ session: HeadlessSession) {
        ensureDirectory()
        var copy = session
        copy.updatedAt = Date()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(copy)
            try data.write(to: fileURL(id: session.id), options: .atomic)
        } catch {
            Log.write("Failed to write session \(session.id): \(error)")
        }
    }

    public static func read(id: String) -> HeadlessSession? {
        guard let data = try? Data(contentsOf: fileURL(id: id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HeadlessSession.self, from: data)
    }

    public static func all() -> [HeadlessSession] {
        ensureDirectory()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> HeadlessSession? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try? decoder.decode(HeadlessSession.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func latest(activeOnly: Bool = false) -> HeadlessSession? {
        all().first { !activeOnly || $0.isActive }
    }

    public static func prune(keep: Int = 40) {
        for session in all().dropFirst(keep) where session.isTerminal {
            try? FileManager.default.removeItem(at: fileURL(id: session.id))
        }
    }

    public static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
    }
}
