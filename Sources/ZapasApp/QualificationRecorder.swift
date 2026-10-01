import AppKit
import ZapasCore

/// Opt-in local evidence only. Normal operation has no diagnostic file writes or input monitor.
@MainActor final class QualificationRecorder {
    private let output: URL
    private var monitor: Any?
    private var clickAt: Double?
    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--qualification-output"), arguments.indices.contains(index + 1) else { return nil }
        let path = arguments[index + 1]
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"), url.pathComponents.contains(".local") else { return nil }
        output = url
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.clickAt = ProcessInfo.processInfo.systemUptime }
            return event
        }
    }
    func visibility(_ visible: Bool) {
        var event: [String: Any] = ["event": "visibility", "visible": visible]
        if visible, let clickAt { event["clickToWindowVisibleMilliseconds"] = (ProcessInfo.processInfo.systemUptime - clickAt) * 1000 }
        clickAt = nil
        append(event)
    }
    func sample(_ frame: DiagnosticFrame) {
        append(["event": "sample", "detailed": frame.detailed, "sleeping": frame.sleeping,
                "systemMeasuredAt": frame.system.map { ISO8601DateFormatter().string(from: $0.measuredAt) } ?? NSNull(),
                "processMeasuredAt": frame.processes.map { ISO8601DateFormatter().string(from: $0.measuredAt) } ?? NSNull(),
                "historyCount": frame.history.count])
    }
    private func append(_ values: [String: Any]) {
        var event = values
        event["recordedAt"] = ISO8601DateFormatter().string(from: Date())
        guard var data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
        data.append(10)
        if !FileManager.default.fileExists(atPath: output.path) {
            FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let file = try? FileHandle(forWritingTo: output) else { return }
        defer { try? file.close() }
        _ = try? file.seekToEnd(); try? file.write(contentsOf: data)
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}
