import Foundation
import Darwin
import CZapas

public enum LocalIPC {
    public static func request(_ request: ProbeRequest, socketPath: String) throws -> ProbeReply {
        let fd = socketPath.withCString { zp_socket_connect($0) }
        guard fd >= 0 else { throw ProbeIssue("ipc_unavailable", "Connect failed (errno \(-fd)); broker may not be running") }
        defer { Darwin.close(fd) }
        try NativeFrame.write(ProbeJSON.encode(request), to: fd)
        guard let body = try NativeFrame.read(from: fd) else { throw ProbeIssue("ipc_disconnected", "Broker closed without a reply") }
        let reply = try ProbeJSON.decode(ProbeReply.self, from: body)
        guard reply.version == 1, reply.requestID == request.requestID else { throw ProbeIssue("ipc_reply_mismatch", "Reply version or requestID mismatch") }
        return reply
    }
    public static func preparePrivateDirectory(_ path: String) throws {
        let manager = FileManager.default
        var directory: ObjCBool = false
        if manager.fileExists(atPath: path, isDirectory: &directory) {
            let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey])
            guard directory.boolValue, values.isSymbolicLink != true else { throw ProbeIssue("ipc_directory", "Runtime directory is not a real directory") }
            let info = try manager.attributesOfItem(atPath: path)
            guard (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw ProbeIssue("ipc_directory", "Runtime directory owner differs") }
            guard let permissions = info[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0 else {
                throw ProbeIssue("ipc_directory", "Existing runtime directory must already be private; permissions are not changed")
            }
        } else {
            try manager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}

public final class ProbeSocketServer {
    private let fd: Int32
    private let path: String
    public init(path: String) throws {
        self.path = path
        let result = path.withCString { zp_socket_listen($0) }
        guard result >= 0 else { throw ProbeIssue("ipc_bind", "Bind failed (errno \(-result)); existing sockets are not replaced") }
        fd = result
    }
    deinit { Darwin.close(fd); path.withCString { _ = unlink($0) } }
    /// One bounded request per connection; serialized state handles multiple profiles without overlapping command execution.
    public func serve(seconds: Double, broker: inout ProbeBroker) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            let ready = zp_wait_readable(fd, 100)
            guard ready >= 0 else { throw ProbeIssue("ipc_poll", "Poll failed (\(ready))") }
            if ready == 0 { continue }
            let client = zp_socket_accept(fd)
            if client < 0 { continue }
            defer { Darwin.close(client) }
            do {
                guard let data = try NativeFrame.read(from: client) else { continue }
                let request = try ProbeJSON.decode(ProbeRequest.self, from: data)
                let reply = broker.handle(request)
                try NativeFrame.write(ProbeJSON.encode(reply), to: client)
            } catch {
                let reply = ProbeReply(requestID: "unparsed", issue: ProbeIssue("invalid_frame_or_message", String(describing: error)))
                try? NativeFrame.write(ProbeJSON.encode(reply), to: client)
            }
        }
    }
}
