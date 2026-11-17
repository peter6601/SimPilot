import Darwin
import Foundation

/// CLI 和 daemon 之間的本機 Unix socket。協定：一行 JSON 請求、一行 JSON 回應，然後關閉。
public enum UnixSocket {
    public enum SocketError: Error, CustomStringConvertible {
        case system(String, Int32)
        case closed
        public var description: String {
            switch self {
            case let .system(op, e): return "\(op): \(String(cString: strerror(e)))"
            case .closed: return "connection closed"
            }
        }
    }

    private static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        return addr
    }

    /// 對方先關掉連線時，write 回 EPIPE 而不是送 SIGPIPE 把整個行程殺掉
    public static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// 連線；失敗回 nil
    public static func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        noSigPipe(fd)
        var addr = address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 { close(fd); return nil }
        return fd
    }

    /// 綁定並 listen。已經有別人在聽就丟錯；殘留的 socket 檔（沒人在聽）會先清掉。
    public static func listen(_ path: String) throws -> Int32 {
        if let fd = connect(path) { close(fd); throw SocketError.system("another daemon is listening on \(path)", EADDRINUSE) }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        var addr = address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { close(fd); throw SocketError.system("bind", errno) }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else { close(fd); throw SocketError.system("listen", errno) }
        return fd
    }

    public static func writeLine(_ fd: Int32, _ data: Data) throws {
        var d = data
        d.append(0x0A)
        try d.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { throw SocketError.system("write", errno) }
                off += n
            }
        }
    }

    /// 讀到換行為止
    public static func readLine(_ fd: Int32, timeout: TimeInterval) throws -> Data {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 { throw SocketError.system("read", errno) }
            if n == 0 { if out.isEmpty { throw SocketError.closed }; return out }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                out.append(contentsOf: buf[0..<nl])
                return out
            }
            out.append(contentsOf: buf[0..<n])
        }
    }

    /// CLI 用：送一個 JSON 請求、等回應
    public static func request(_ path: String, _ body: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        guard let fd = connect(path) else { throw SocketError.system("connect \(path)", ECONNREFUSED) }
        defer { close(fd) }
        try writeLine(fd, try JSONSerialization.data(withJSONObject: body))
        let line = try readLine(fd, timeout: timeout)
        return (try JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? ["ok": false, "error": "bad_response"]
    }
}
