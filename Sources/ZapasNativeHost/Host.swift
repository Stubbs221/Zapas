import Foundation
import Darwin
import ZapasCore

@main
struct NativeHost {
    static func main() {
        do {
            let environment = ProcessInfo.processInfo.environment
            if environment["ZAPAS_PRODUCTION"] == "1" || FileManager.default.fileExists(atPath: CommandLine.arguments[0] + ".json") {
                try production(environment: environment)
                return
            }
            guard let allowed = environment["ZAPAS_ALLOWED_ORIGIN"], let socket = environment["ZAPAS_SOCKET"],
                  CommandLine.arguments.count >= 2 else { throw ProbeIssue("host_configuration", "Explicit origin and socket configuration required") }
            try NativeOrigin.validate(CommandLine.arguments[1], allowed: allowed)
            let sessionID = UUID().uuidString
            while let data = try NativeFrame.read(from: STDIN_FILENO) {
                var reply: ProbeReply
                do {
                    var request = try ProbeJSON.decode(ProbeRequest.self, from: data)
                    try request.validate()
                    guard [.hello, .publishTabs, .pollTestAction, .submitResult].contains(request.operation) else {
                        throw ProbeIssue("host_operation_denied", "Extension channel cannot enqueue actions or arbitrary commands")
                    }
                    // The extension cannot forge another profile's host identity.
                    request.origin = allowed; request.sessionID = sessionID
                    reply = try LocalIPC.request(request, socketPath: socket)
                    reply.sessionID = sessionID
                } catch {
                    let requestID = (try? ProbeJSON.decode(ProbeRequest.self, from: data))?.requestID ?? "unparsed"
                    reply = ProbeReply(requestID: requestID, issue: error as? ProbeIssue ?? ProbeIssue("host_message", String(describing: error)))
                    reply.sessionID = sessionID
                }
                try NativeFrame.write(ProbeJSON.encode(reply), to: STDOUT_FILENO)
            }
        } catch {
            let issue = error as? ProbeIssue ?? ProbeIssue("host_failed", String(describing: error))
            if let data = try? ProbeJSON.encode(issue) { try? FileHandle.standardError.write(contentsOf: data + Data([10])) }
            exit(1)
        }
    }
    static func production(environment: [String: String]) throws {
        let configuration: NativeConfiguration
        if environment["ZAPAS_PRODUCTION"] == "1", let origin = environment["ZAPAS_ALLOWED_ORIGIN"], let socket = environment["ZAPAS_SOCKET"] {
            configuration = NativeConfiguration(origin: origin, socket: socket)
        } else {
            configuration = try ProbeJSON.decode(NativeConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0] + ".json")))
        }
        guard CommandLine.arguments.count >= 2 else { throw ProbeIssue("origin_denied", "Origin required") }
        try NativeOrigin.validate(CommandLine.arguments[1], allowed: configuration.origin)
        let session = UUID().uuidString
        var profile: String?
        while let data = try NativeFrame.read(from: STDIN_FILENO) {
            var reply: ServiceReply
            do {
                var request = try ProbeJSON.decode(ServiceRequest.self, from: data)
                try request.validate()
                guard ["chromeHello", "chromePublish", "chromePoll", "chromeResult", "chromeDisconnect"].contains(request.operation),
                      let requestedProfile = request.profileID else { throw ProbeIssue("host_operation_denied", "Only extension observations and results are allowed") }
                if let profile, profile != requestedProfile { throw ProbeIssue("profile_changed", "Host profile identity is immutable") }
                profile = requestedProfile
                request.origin = configuration.origin; request.sessionID = session
                reply = try ServiceIPC.request(request, socketPath: configuration.socket)
                reply.sessionID = session
            } catch {
                let id = (try? ProbeJSON.decode(ServiceRequest.self, from: data))?.requestID ?? "unparsed"
                reply = ServiceReply(requestID: id, issue: error as? ProbeIssue ?? ProbeIssue("host_message", "Invalid production message"))
                reply.sessionID = session
            }
            try NativeFrame.write(ProbeJSON.encode(reply), to: STDOUT_FILENO)
        }
        // EOF is a disconnect, not evidence that an in-flight command failed.
        if let profile {
            var request = ServiceRequest("chromeDisconnect")
            request.profileID = profile; request.sessionID = session; request.origin = configuration.origin
            _ = try? ServiceIPC.request(request, socketPath: configuration.socket)
        }
    }

}
