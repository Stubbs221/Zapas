import Foundation
import Darwin

public struct NativeConfiguration: Codable, Sendable {
    public let origin: String
    public let socket: String
    public init(origin: String, socket: String) { self.origin = origin; self.socket = socket }
}
public enum NativeInstallation {
    public static let hostName = "com.zapas.chrome"
    /// Explicitly chosen Chrome user-data directory. Does not load an extension or change profile preferences.
    public static func install(hostExecutable: URL, userDataDirectory: URL, runtime: String = ServiceLocation.runtime) throws -> URL {
        let manager = FileManager.default
        try LocalIPC.preparePrivateDirectory(runtime)
        let directory = URL(fileURLWithPath: runtime).appendingPathComponent("native")
        try LocalIPC.preparePrivateDirectory(directory.path)
        let hosts = userDataDirectory.appendingPathComponent("NativeMessagingHosts")
        guard manager.fileExists(atPath: userDataDirectory.path) else { throw ProbeIssue("install_directory", "Select an existing Chrome user-data directory") }
        for url in [userDataDirectory, hosts] where manager.fileExists(atPath: url.path) {
            let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard info.isSymbolicLink != true, info.isDirectory == true,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw ProbeIssue("install_directory", "Installation directory must be real and owned by current user") }
        }
        let binary = directory.appendingPathComponent("zapas-native-host")
        let config = URL(fileURLWithPath: binary.path + ".json")
        let manifest = hosts.appendingPathComponent(hostName + ".json")
        for url in [manifest, binary, config] {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
                    throw ProbeIssue("install_conflict", "Existing native files must be regular and owned by current user")
                }
            } else if errno != ENOENT {
                throw ProbeIssue("install_conflict", "Cannot inspect existing native path safely")
            }
        }
        let expected: [String: Any] = ["name": hostName, "description": "Zapas Chrome — локальная связь", "path": binary.path, "type": "stdio", "allowed_origins": [ServiceLocation.origin]]
        if manager.fileExists(atPath: manifest.path) {
            let info = try manifest.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard info.isSymbolicLink != true,
                  let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
                  existing["name"] as? String == hostName, existing["path"] as? String == binary.path,
                  existing["allowed_origins"] as? [String] == [ServiceLocation.origin] else { throw ProbeIssue("install_conflict", "Existing host belongs to a different installation; nothing replaced") }
        }
        if manager.fileExists(atPath: binary.path) || manager.fileExists(atPath: config.path) {
            guard let existing = try? ProbeJSON.decode(NativeConfiguration.self, from: Data(contentsOf: config)),
                  existing.origin == ServiceLocation.origin, existing.socket == runtime + "/gui.sock" else { throw ProbeIssue("install_conflict", "Native files belong to a different installation") }
            for url in [binary, config] {
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ProbeIssue("install_conflict", "Native path is a symlink") }
            }
        }
        guard manager.isExecutableFile(atPath: hostExecutable.path) else { throw ProbeIssue("install_binary", "Bundled Native Messaging executable missing") }
        let binaryData = try Data(contentsOf: hostExecutable)
        let configData = try ProbeJSON.encode(NativeConfiguration(origin: ServiceLocation.origin, socket: runtime + "/gui.sock"))
        let manifestData = try JSONSerialization.data(withJSONObject: expected, options: [.prettyPrinted, .sortedKeys])
        // Prepare the executable and configuration before publishing the manifest. Failed installation is visible to caller.
        try binaryData.write(to: binary, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try configData.write(to: config, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        if !manager.fileExists(atPath: hosts.path) { try manager.createDirectory(at: hosts, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try manifestData.write(to: manifest, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        return manifest
    }
}
