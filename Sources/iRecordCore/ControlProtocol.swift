import Foundation

public struct ControlRequest: Codable, Sendable {
    public var command: String
    public var session: String?

    public init(command: String, session: String? = nil) {
        self.command = command
        self.session = session
    }
}

public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var state: String?
    public var session: String?
    public var outputPath: String?
    public var elapsed: Double?
    public var error: String?
    public var code: String?
    public var result: RecordingResult?

    public init(
        ok: Bool,
        state: String? = nil,
        session: String? = nil,
        outputPath: String? = nil,
        elapsed: Double? = nil,
        error: String? = nil,
        code: String? = nil,
        result: RecordingResult? = nil
    ) {
        self.ok = ok
        self.state = state
        self.session = session
        self.outputPath = outputPath
        self.elapsed = elapsed
        self.error = error
        self.code = code
        self.result = result
    }
}

public enum UnixSocketError: Error, LocalizedError {
    case socketFailed(String)
    case connectFailed(String)
    case timeout
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .socketFailed(let detail): return "Could not create a control socket: \(detail)"
        case .connectFailed(let detail): return "No active recording session (\(detail)). Start one with `irecord start`."
        case .timeout: return "The recording session did not respond in time."
        case .invalidResponse: return "The recording session returned an invalid response."
        }
    }
}

public enum ControlClient {
    public static func request(_ request: ControlRequest, timeout: TimeInterval = 10, socketPath: String = AppPaths.controlSocket.path) throws -> ControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UnixSocketError.socketFailed(String(cString: strerror(errno)))
        }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw UnixSocketError.connectFailed("socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: pathBytes)
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, length)
            }
        }
        guard connectResult == 0 else {
            throw UnixSocketError.connectFailed(String(cString: strerror(errno)))
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var payload = try encoder.encode(request)
        payload.append(0x0A)
        try payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 {
                    throw UnixSocketError.connectFailed(String(cString: strerror(errno)))
                }
                offset += written
            }
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
            if data.contains(0x0A) { break }
            if data.count > 4_000_000 { break }
        }
        guard !data.isEmpty else { throw UnixSocketError.invalidResponse }
        if let newline = data.firstIndex(of: 0x0A) {
            data = data.prefix(upTo: newline)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ControlResponse.self, from: data)
    }

    public static func isSessionActive(socketPath: String = AppPaths.controlSocket.path) -> Bool {
        (try? request(ControlRequest(command: "status"), timeout: 1, socketPath: socketPath))?.ok == true
    }
}

/// A minimal line-delimited JSON server over a Unix domain socket.
public final class ControlServer {
    public typealias Handler = (ControlRequest) -> ControlResponse

    public let socketPath: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.irecord.control.server")
    private var listenFD: Int32 = -1
    private var running = false
    private let lock = NSLock()

    public init(socketPath: String = AppPaths.controlSocket.path, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public func start() throws {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.socketFailed(String(cString: strerror(errno))) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw UnixSocketError.socketFailed("socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: pathBytes)
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, length)
            }
        }
        guard bindResult == 0 else {
            let detail = String(cString: strerror(errno))
            close(fd)
            throw UnixSocketError.socketFailed(detail)
        }
        guard listen(fd, 8) == 0 else {
            let detail = String(cString: strerror(errno))
            close(fd)
            throw UnixSocketError.socketFailed(detail)
        }
        chmod(socketPath, 0o600)
        listenFD = fd
        running = true

        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        lock.lock()
        running = false
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let running = self.running
            let fd = listenFD
            lock.unlock()
            guard running, fd >= 0 else { return }

            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                usleep(50_000)
                continue
            }
            handleClient(client)
        }
    }

    private func handleClient(_ client: Int32) {
        defer { close(client) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
            if data.contains(0x0A) { break }
            if data.count > 1_000_000 { break }
        }
        guard !data.isEmpty else { return }
        if let newline = data.firstIndex(of: 0x0A) {
            data = data.prefix(upTo: newline)
        }

        let response: ControlResponse
        do {
            let request = try JSONDecoder().decode(ControlRequest.self, from: data)
            response = handler(request)
        } catch {
            response = ControlResponse(ok: false, error: "Invalid request: \(error.localizedDescription)", code: "invalid_request")
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if var payload = try? encoder.encode(response) {
            payload.append(0x0A)
            payload.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(client, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }
    }
}
