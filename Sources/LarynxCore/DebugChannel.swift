import Foundation

/// A local unix socket (~/.larynx/debug.sock) for headless probes: `larynx debug feed <wav>`.
/// Not a network port. Only a debug build of the app opens it, and only when launched with LARYNX_DEBUG=1.
/// One request line of JSON in, one reply line of JSON out.
public enum DebugChannel {
    public static var path: URL { Paths.home.appendingPathComponent("debug.sock") }

    /// The release app never trusts its environment (see `Paths.trustsEnvironment`), so this is always off there.
    public static var enabled: Bool { Paths.trustsEnvironment && ProcessInfo.processInfo.environment["LARYNX_DEBUG"] == "1" }

    /// A request line longer than this is refused.
    static let maxRequest = 64 * 1024
    /// A client that sends nothing for this long is dropped.
    static let readTimeout = 5

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        init(_ d: String) { description = d }
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        return addr
    }

    /// Client side: send one request, wait for one reply.
    public static func request(_ body: Data, timeout: Int = 120) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("socket() failed") }
        defer { close(fd) }
        var addr = try address(path.path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else {
            throw Failure("Larynx is not listening on \(path.path). Start a debug build with: swift build --product LarynxApp && LARYNX_DEBUG=1 .build/debug/LarynxApp &")
        }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var line = body
        line.append(0x0A)
        try writeAll(fd, line)
        return try readLine(fd)
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                guard n > 0 else { throw Failure("write failed") }
                off += n
            }
        }
    }

    static func readLine(_ fd: Int32, limit: Int = .max) throws -> Data {
        var out = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { if out.isEmpty { throw Failure("no reply") }; break }
            if byte == 0x0A { break }
            guard out.count < limit else { throw Failure("line too long") }
            out.append(byte)
        }
        return out
    }

    /// Server side: accept connections on a background thread. `handle` gets each request
    /// and calls `reply` once with the answer.
    public static func serve(_ handle: @escaping @Sendable (Data, @escaping @Sendable (Data) -> Void) -> Void) throws {
        try Paths.ensurePrivateDir(Paths.home)
        unlink(path.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure("socket() failed") }
        var addr = try address(path.path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); throw Failure("bind/listen failed on \(path.path)") }
        chmod(path.path, 0o600)
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                var tv = timeval(tv_sec: readTimeout, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var on: Int32 = 1 // a client that hangs up early must not kill the app with SIGPIPE
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                // Each client on its own thread, so one slow client never holds up the next.
                Thread.detachNewThread {
                    guard let req = try? readLine(client, limit: maxRequest) else { close(client); return }
                    handle(req) { answer in
                        var line = answer
                        line.append(0x0A)
                        try? writeAll(client, line)
                        close(client)
                    }
                }
            }
        }
    }
}
