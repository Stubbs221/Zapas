import Foundation
import Darwin
import ZapasCore

@main
struct NativeHost {
    static func main() {
        do {
            let environment = ProcessInfo.processInfo.environment
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
}
