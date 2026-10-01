import Foundation

public struct SimulatorDevice: Codable, Sendable, Equatable {
    public let name: String
    public let udid: String
    public let runtime: String
    public let state: String
    public let isAvailable: Bool
    public let dataPath: String?
    public let assignment: String
    public let isIOS: Bool
}

public struct SimulatorSnapshot: Encodable, Sendable {
    public let schemaVersion = 1
    public let measuredAt: Date
    public let totalDeviceCount: Int
    public let devices: [SimulatorDevice]
    public let issue: ProbeIssue?
}

public enum SimulatorInventory {
    private struct DeviceList: Decodable { let devices: [String: [Device]] }
    private struct Device: Decodable {
        let name: String; let udid: String; let state: String; let isAvailable: Bool; let dataPath: String?
    }
    public static func decode(_ data: Data, assignedUDIDs: Set<String> = []) throws -> SimulatorSnapshot {
        let list = try JSONDecoder().decode(DeviceList.self, from: data)
        var output: [SimulatorDevice] = []
        for (runtime, devices) in list.devices {
            for device in devices {
                guard UUID(uuidString: device.udid) != nil else { throw ProbeIssue("invalid_device_id", "simctl returned an invalid UDID") }
                output.append(SimulatorDevice(name: device.name, udid: device.udid, runtime: runtime, state: device.state,
                                              isAvailable: device.isAvailable, dataPath: device.dataPath,
                                              assignment: assignedUDIDs.contains(device.udid) ? "Zapas" : "unknown_or_other_project",
                                              isIOS: runtime.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-")))
            }
        }
        output.sort { $0.runtime == $1.runtime ? $0.name < $1.name : $0.runtime < $1.runtime }
        return SimulatorSnapshot(measuredAt: Date(), totalDeviceCount: output.count, devices: output, issue: nil)
    }
    public static func requireAssignedIOS(_ device: SimulatorDevice) throws {
        guard device.isIOS, device.isAvailable, device.assignment == "Zapas" else {
            throw ProbeIssue("device_not_authorized", "Requires an available iOS device explicitly assigned to Zapas")
        }
    }
    public static func associations(path: String?, devices: [SimulatorDevice]) -> [String] {
        guard let path else { return [] }
        // No inference from device names or generic Simulator.app. Only a concrete device data directory is evidence.
        return devices.compactMap { device in
            guard let dataPath = device.dataPath, path.hasPrefix(dataPath + "/") else { return nil }
            return device.udid
        }
    }
    public static func read(assignedUDIDs: Set<String> = []) throws -> SimulatorSnapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "-j"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        guard process.terminationStatus == 0 else {
            throw ProbeIssue("simctl_unavailable", "xcrun simctl failed (status \(process.terminationStatus)); Xcode/service/access may be unavailable")
        }
        return try decode(data, assignedUDIDs: assignedUDIDs)
    }
}
