import Foundation

struct CLIArgs {
    let command: String
    let rawArguments: [String]
    private var values: [String: String] = [:]
    private var positionals: [String] = []

    private static let booleanFlags: Set<String> = [
        "json", "quiet", "verbose", "help", "all", "windows", "displays",
        "overwrite", "no-audio", "no-cursor", "no-mouse-clicks", "mouse-clicks",
        "cursor", "daemon", "debug", "wait", "active", "include-system", "displays-only"
    ]

    init(_ arguments: [String]) {
        var args = arguments
        if args.isEmpty {
            command = "help"
        } else {
            command = args.removeFirst()
        }
        rawArguments = args

        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--") {
                let trimmed = String(arg.dropFirst(2))
                if let equals = trimmed.firstIndex(of: "=") {
                    let key = String(trimmed[..<equals]).lowercased()
                    let value = String(trimmed[trimmed.index(after: equals)...])
                    values[key] = value
                    index += 1
                    continue
                }
                let key = trimmed.lowercased()
                if Self.booleanFlags.contains(key) {
                    values[key] = "true"
                    index += 1
                } else if index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                    values[key] = args[index + 1]
                    index += 2
                } else {
                    values[key] = "true"
                    index += 1
                }
            } else if arg.hasPrefix("-"), arg.count == 2 {
                let key = String(arg.dropFirst()).lowercased()
                let mapping: [String: String] = [
                    "h": "help", "j": "json", "q": "quiet", "v": "verbose",
                    "o": "output", "f": "format", "d": "duration", "w": "window",
                    "s": "session", "m": "mode", "a": "audio", "r": "region"
                ]
                let name = mapping[key] ?? key
                if Self.booleanFlags.contains(name) {
                    values[name] = "true"
                    index += 1
                } else if index + 1 < args.count {
                    values[name] = args[index + 1]
                    index += 2
                } else {
                    values[name] = "true"
                    index += 1
                }
            } else {
                positionals.append(arg)
                index += 1
            }
        }
    }

    func string(_ names: String...) -> String? {
        for name in names {
            if let value = values[name.lowercased()], value != "true" { return value }
        }
        return nil
    }

    func raw(_ names: String...) -> String? {
        for name in names {
            if let value = values[name.lowercased()] { return value }
        }
        return nil
    }

    func has(_ names: String...) -> Bool {
        for name in names {
            if let value = values[name.lowercased()], value == "true" || value == "yes" || value == "1" {
                return true
            }
        }
        return false
    }

    func bool(_ names: String..., default defaultValue: Bool = false) -> Bool {
        for name in names {
            guard let value = values[name.lowercased()] else { continue }
            switch value.lowercased() {
            case "true", "yes", "1", "on": return true
            case "false", "no", "0", "off": return false
            default: return defaultValue
            }
        }
        return defaultValue
    }

    func int(_ names: String...) -> Int? {
        for name in names {
            if let raw = values[name.lowercased()], let value = Int(raw) { return value }
        }
        return nil
    }

    func double(_ names: String...) -> Double? {
        for name in names {
            if let raw = values[name.lowercased()], let value = Double(raw) { return value }
        }
        return nil
    }

    var positional: [String] { positionals }
    var wantsJSON: Bool { has("json") }
    var isQuiet: Bool { has("quiet") }
    var isVerbose: Bool { has("verbose") }
}

enum CLIExit: Int32 {
    case ok = 0
    case general = 1
    case usage = 2
    case permission = 3
    case target = 4
    case output = 5
    case timeout = 6
    case cancelled = 130
}

enum CLIOutput {
    static func json(_ object: [String: Any], exitCode: CLIExit = .ok) -> Never {
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(
               withJSONObject: object,
               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
           ) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            FileHandle.standardOutput.write(Data("{\"ok\":false,\"error\":\"Could not encode JSON output\"}\n".utf8))
        }
        exit(exitCode.rawValue)
    }

    static func error(
        _ message: String,
        code: String,
        json: Bool,
        exitCode: CLIExit = .general,
        hint: String? = nil
    ) -> Never {
        if json {
            var object: [String: Any] = ["ok": false, "error": message, "code": code]
            if let hint { object["hint"] = hint }
            Self.json(object, exitCode: exitCode)
        }
        write("irecord: \(message)", to: .standardError)
        if let hint { write("hint: \(hint)", to: .standardError) }
        exit(exitCode.rawValue)
    }

    static func line(_ text: String = "") {
        write(text, to: .standardOutput)
    }

    static func info(_ text: String, quiet: Bool = false) {
        guard !quiet else { return }
        write(text, to: .standardError)
    }

    static func write(_ text: String, to handle: FileHandle) {
        if let data = (text + "\n").data(using: .utf8) {
            handle.write(data)
        }
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
