import Foundation

public struct ProbeIssue: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var description: String { "\(code): \(message)" }
}

public struct Metric: Codable, Sendable {
    public let value: Double?
    public let unit: String
    public let source: String
    public let measuredAt: Date
    public let issue: ProbeIssue?

    public init(_ value: Double, unit: String = "bytes", source: String, at: Date) {
        self.value = value; self.unit = unit; self.source = source; self.measuredAt = at; self.issue = nil
    }
    public init(unavailable issue: ProbeIssue, unit: String = "bytes", source: String, at: Date) {
        self.value = nil; self.unit = unit; self.source = source; self.measuredAt = at; self.issue = issue
    }
}

public enum ProbeJSON {
    public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
