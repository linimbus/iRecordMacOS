import Foundation

public enum AppInfo {
    public static let version = "1.1.0"
    public static let build = "2"
    public static let bundleIdentifier = "com.irecord.app"
    public static let displayName = "iRecord"
    public static let cliName = "irecord"
}

public enum AppPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("iRecord", isDirectory: true)
    }

    public static var settingsFile: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    public static var sessionsDirectory: URL {
        supportDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    public static var controlSocket: URL {
        supportDirectory.appendingPathComponent("control.sock")
    }

    public static var defaultOutputDirectory: URL {
        let movies = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return movies.appendingPathComponent("iRecord", isDirectory: true)
    }

    public static var logFile: URL {
        supportDirectory.appendingPathComponent("irecord.log")
    }

    @discardableResult
    public static func ensureDirectories() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: defaultOutputDirectory,
                withIntermediateDirectories: true
            )
            return true
        } catch {
            return false
        }
    }

    public static func timestampedFileName(format: VideoFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return "iRecord-\(formatter.string(from: Date())).\(format.fileExtension)"
    }

    public static func availableOutputURL(
        directory: URL,
        preferredName: String? = nil,
        format: VideoFormat
    ) -> URL {
        let fm = FileManager.default
        let name = preferredName ?? timestampedFileName(format: format)
        var candidate = directory.appendingPathComponent(name)
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            let base = name.replacingOccurrences(of: ".\(format.fileExtension)", with: "")
            candidate = directory.appendingPathComponent("\(base)-\(index).\(format.fileExtension)")
            index += 1
        }
        return candidate
    }
}

public enum Log {
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: AppPaths.logFile.path),
               let handle = try? FileHandle(forWritingTo: AppPaths.logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: AppPaths.logFile)
            }
        }
    }
}
