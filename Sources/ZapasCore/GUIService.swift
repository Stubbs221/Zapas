import Foundation
import Darwin
import CZapas

public enum ServiceLocation {
    public static var runtime: String {
        ProcessInfo.processInfo.environment["ZAPAS_RUNTIME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Zapas/run").path
    }
    public static var socket: String { runtime + "/gui.sock" }
    public static let origin = "chrome-extension://eolgbpamlmkkcbiahkdakmibcjfjhpip/"
}
public enum ServiceIPC {
    public static func request(_ request: ServiceRequest, socketPath: String = ServiceLocation.socket) throws -> ServiceReply {
        let fd = socketPath.withCString { zp_socket_connect($0) }
        guard fd >= 0 else { throw ProbeIssue("ipc_unavailable", "GUI service unavailable (errno \(-fd))") }
        defer { Darwin.close(fd) }
        if ["simulatorsList", "simulatorsPreview", "debuggersList", "debuggersPreview", "developmentApply"].contains(request.operation) {
            var timeout = timeval(tv_sec: 45, tv_usec: 0)
            _ = withUnsafePointer(to: &timeout) { setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
        }
        try NativeFrame.write(ProbeJSON.encode(request), to: fd)
        guard let body = try NativeFrame.read(from: fd) else { throw ProbeIssue("ipc_disconnected", "Service closed without reply") }
        let reply = try ProbeJSON.decode(ServiceReply.self, from: body)
        guard reply.version == 1, reply.requestID == request.requestID else { throw ProbeIssue("ipc_reply_mismatch", "Reply correlation mismatch") }
        return reply
    }
    #if compiler(>=6.2)
    @concurrent
    #endif
    public static func asyncRequest(_ request: ServiceRequest, socketPath: String = ServiceLocation.socket) async throws -> ServiceReply {
        try self.request(request, socketPath: socketPath)
    }
}

/// Blocking socket I/O is confined to this queue. Mutable lifecycle is protected by lock.
/// A private advisory lock owns the service path across startup, crash recovery and clean exit.
public final class GUIServiceListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.zapas.service.io", qos: .utility)
    private let lock = NSLock()
    private var stopped = false
    private let fd: Int32
    private let lease: Int32
    private let path: String
    private let handler: @Sendable (ServiceRequest) async -> ServiceReply
    public init(runtime: String = ServiceLocation.runtime, handler: @escaping @Sendable (ServiceRequest) async -> ServiceReply) throws {
        try LocalIPC.preparePrivateDirectory(runtime)
        self.handler = handler; path = runtime + "/gui.sock"
        let lockPath = runtime + "/service.lock"
        let lease = lockPath.withCString { open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard lease >= 0 else { throw ProbeIssue("ipc_lease", "Cannot open service lease") }
        var info = stat()
        guard fstat(lease, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_mode & S_IFMT == S_IFREG, flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lease); throw ProbeIssue("service_already_running", "Private service lease unavailable; another GUI may be running")
        }
        self.lease = lease
        var socketInfo = stat()
        if lstat(path, &socketInfo) == 0 {
            guard socketInfo.st_mode & S_IFMT == S_IFSOCK, socketInfo.st_uid == getuid(), socketInfo.st_mode & 0o077 == 0 else {
                Darwin.close(lease); throw ProbeIssue("ipc_path_unsafe", "Existing path is not an owned private socket")
            }
            // Even with the lease, never remove a live service not following our lease protocol.
            let live = path.withCString { zp_socket_connect($0) }
            if live >= 0 { Darwin.close(live); Darwin.close(lease); throw ProbeIssue("service_already_running", "An existing service answers on this socket") }
            guard live == -ECONNREFUSED else { Darwin.close(lease); throw ProbeIssue("ipc_recovery", "Existing socket failure is not proven stale") }
            guard path.withCString({ unlink($0) }) == 0 else { Darwin.close(lease); throw ProbeIssue("ipc_recovery", "Could not recover stale socket") }
        }
        let result = path.withCString { zp_socket_listen($0) }
        guard result >= 0 else { Darwin.close(lease); throw ProbeIssue("ipc_bind", "Bind failed (errno \(-result))") }
        fd = result
    }
    public func start() { queue.async { [self] in next() } }
    public func stop() { lock.withLock { stopped = true } }
    private func next() {
        guard !lock.withLock({ stopped }) else { return }
        let ready = zp_wait_readable(fd, 100)
        guard ready > 0 else { queue.async { [self] in next() }; return }
        let client = zp_socket_accept(fd)
        guard client >= 0 else { queue.async { [self] in next() }; return }
        do {
            guard let data = try NativeFrame.read(from: client) else { Darwin.close(client); queue.async { [self] in next() }; return }
            let request = try ProbeJSON.decode(ServiceRequest.self, from: data)
            Task { [self] in
                let reply = await handler(request)
                queue.async { [self] in
                    do { try NativeFrame.write(ProbeJSON.encode(reply), to: client) }
                    catch { try? NativeFrame.write(ProbeJSON.encode(ServiceReply(requestID: request.requestID, issue: ProbeIssue("ipc_reply_failed", "Reply unavailable or exceeds 1 MiB"))), to: client) }
                    Darwin.close(client); next()
                }
            }
        } catch {
            let reply = ServiceReply(requestID: "unparsed", issue: ProbeIssue("invalid_frame_or_message", "Invalid frame or schema"))
            try? NativeFrame.write(ProbeJSON.encode(reply), to: client)
            Darwin.close(client); queue.async { [self] in next() }
        }
    }
    deinit { Darwin.close(fd); path.withCString { _ = unlink($0) }; Darwin.close(lease) }
}

public actor GUIService {
    private let coordinator: SamplingCoordinator
    private var broker: ChromeBroker
    private let development: DevelopmentActions
    public init(coordinator: SamplingCoordinator, origin: String = ServiceLocation.origin, policies: [String: [String]] = [:]) throws {
        self.coordinator = coordinator; development = DevelopmentActions(coordinator: coordinator); broker = try ChromeBroker(allowedOrigin: origin)
        guard policies.count <= 32 else { throw ProbeIssue("exclusion_schema", "Too many profile policies") }
        for (id, domains) in policies { try broker.setPolicy(ChromePolicy(excludedDomains: domains), profileID: id) }
    }
    public func profiles() -> [ChromeProfile] { broker.snapshot() }
    public func suspend() async { broker.suspend(); await development.suspend() }
    public func setSimulatorAssignment(_ path: String) async throws { try await development.setAssignmentPath(path) }
    public func setPolicy(_ policy: ChromePolicy, profileID: String) throws { try broker.setPolicy(policy, profileID: profileID) }
    public func handle(_ request: ServiceRequest) async -> ServiceReply {
        do { try request.validate() } catch { return ServiceReply(requestID: request.requestID, issue: error as? ProbeIssue ?? ProbeIssue("invalid_request", "Invalid request")) }
        if ["simulatorsList", "debuggersList", "simulatorsPreview", "debuggersPreview", "developmentApply", "developmentResult"].contains(request.operation) { return await development.handle(request) }
        if request.operation == "status" || request.operation == "processes" {
            let frame = await coordinator.refresh(includeProcesses: request.operation == "processes")
            var reply = ServiceReply(requestID: request.requestID)
            reply.serviceID = broker.serviceID; reply.system = frame.system; reply.processes = frame.processes
            reply.systemError = frame.systemError; reply.processError = frame.processError
            return reply
        }
        if request.operation == "tabsApply" {
            let frame = await coordinator.refresh(includeProcesses: true)
            var reply = broker.handle(request)
            if let batch = reply.batch {
                let value = ChromeGroupMeasurement.summarize(frame.processes, error: frame.processError)
                broker.measurement(value, planID: batch.plan.id, before: true)
                var result = ServiceRequest("tabsResult"); result.planID = batch.plan.id
                reply.batch = broker.handle(result).batch
            }
            return reply
        }
        var reply = broker.handle(request)
        if request.operation == "tabsResult", let batch = reply.batch, batch.after == nil,
           batch.results.allSatisfy({ $0.issue != "awaiting_confirmation" }) {
            let frame = await coordinator.refresh(includeProcesses: true)
            broker.measurement(ChromeGroupMeasurement.summarize(frame.processes, error: frame.processError), planID: batch.plan.id, before: false)
            reply = broker.handle(request)
        }
        return reply
    }
}
