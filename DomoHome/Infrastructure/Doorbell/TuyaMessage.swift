import Foundation

enum TuyaDPValue: Codable, Equatable, Sendable {
    case boolean(Bool)
    case integer(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .boolean(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    var integer: Int? {
        switch self {
        case .integer(let value): value
        case .string(let value): Int(value)
        case .boolean: nil
        }
    }

    var isTrue: Bool {
        self == .boolean(true) || self == .integer(1) || self == .string("true") || self == .string("1")
    }
}

struct TuyaMessage: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var type = "property"
    var state: String?
    var environment: String?
    var deviceId: String?
    var dataId: String?
    var messageId: String?
    var dpId: Int?
    var code: String?
    var value: TuyaDPValue?
    var eventTimeMs: Int64?
    var publishedAt: String?

    var publishedDate: Date? {
        guard let publishedAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: publishedAt) ?? ISO8601DateFormatter().date(from: publishedAt)
    }
}

enum TuyaMessageError: String, Error, Sendable {
    case decodingFailure = "DecodingFailure"
    case authFailure = "AuthFailure"
    case connectionLost = "ConnectionLost"
    case configurationMissing = "ConfigurationMissing"
}

protocol TuyaMessageStream: Sendable {
    func messages() -> AsyncStream<TuyaMessage>
    func stop()
}

final class MockTuyaMessageStream: TuyaMessageStream, @unchecked Sendable {
    private let stream: AsyncStream<TuyaMessage>
    private let continuation: AsyncStream<TuyaMessage>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(128))
    }

    func messages() -> AsyncStream<TuyaMessage> { stream }
    func send(_ message: TuyaMessage) { continuation.yield(message) }
    func stop() { continuation.finish() }
}

struct TuyaDoorbellSettings: Equatable, Sendable {
    enum Environment: String, CaseIterable, Sendable {
        case test = "TEST"
        case production = "PROD"
    }

    var enabled: Bool
    var notificationsEnabled: Bool
    var environment: Environment
    var maxEventAge: TimeInterval
    var maxClockSkew: TimeInterval

    init(defaults: UserDefaults = .standard, bundleEnvironment: String? = Bundle.main.object(forInfoDictionaryKey: "DomoHomeTuyaMessageEnvironment") as? String) {
        enabled = defaults.bool(forKey: "tuyaDoorbellEnabled")
        notificationsEnabled = defaults.object(forKey: "tuyaDoorbellNotifications") as? Bool ?? true
        environment = Environment(rawValue: defaults.string(forKey: "tuyaDoorbellEnvironment") ?? bundleEnvironment ?? "PROD") ?? .production
        maxEventAge = defaults.object(forKey: "tuyaDoorbellMaxEventAge") as? Double ?? 10
        maxClockSkew = defaults.object(forKey: "tuyaDoorbellMaxClockSkew") as? Double ?? 2
        maxEventAge = min(30, max(1, maxEventAge.isFinite ? maxEventAge : 10))
        maxClockSkew = min(3, max(0, maxClockSkew.isFinite ? maxClockSkew : 2))
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: "tuyaDoorbellEnabled")
        defaults.set(notificationsEnabled, forKey: "tuyaDoorbellNotifications")
        defaults.set(environment.rawValue, forKey: "tuyaDoorbellEnvironment")
        defaults.set(maxEventAge, forKey: "tuyaDoorbellMaxEventAge")
        defaults.set(maxClockSkew, forKey: "tuyaDoorbellMaxClockSkew")
    }
}

struct DoorbellMetrics: Equatable, Sendable {
    private(set) var eventToPublish: [Double] = []
    private(set) var publishToReceive: [Double] = []
    private(set) var eventToNotification: [Double] = []

    mutating func recordEvent(event: Date, published: Date, received: Date) {
        eventToPublish.append(max(0, published.timeIntervalSince(event)))
        publishToReceive.append(max(0, received.timeIntervalSince(published)))
        eventToPublish = Array(eventToPublish.suffix(256))
        publishToReceive = Array(publishToReceive.suffix(256))
    }

    mutating func recordNotification(event: Date, delivered: Date) {
        eventToNotification.append(max(0, delivered.timeIntervalSince(event)))
        eventToNotification = Array(eventToNotification.suffix(256))
    }

    static func percentiles(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "—" }
        let sorted = values.sorted()
        let p50 = sorted[max(0, Int(ceil(Double(sorted.count) * 0.50)) - 1)]
        let p95 = sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        return String(format: "%.2f / %.2f s (n=%d)", p50, p95, values.count)
    }
}

@MainActor
protocol DoorbellAlertPresenting: AnyObject {
    func present(_ snapshot: DoorbellSnapshot) -> Bool
    func update(_ snapshot: DoorbellSnapshot)
    func dismiss()
}

@MainActor
final class DoorbellAlertDelivery {
    private let presenter: any DoorbellAlertPresenting
    private var sessionID: UUID?

    init(presenter: any DoorbellAlertPresenting) {
        self.presenter = presenter
    }

    func receiveCall(_ snapshot: DoorbellSnapshot, enabled: Bool) -> Bool {
        guard enabled, let id = snapshot.sessionID,
              [.ringing, .available].contains(snapshot.phase) else { return false }
        guard sessionID != id else { presenter.update(snapshot); return false }
        sessionID = id
        return !presenter.present(snapshot)
    }

    func update(_ snapshot: DoorbellSnapshot) {
        guard let sessionID else { return }
        guard snapshot.sessionID == sessionID, [.ringing, .available].contains(snapshot.phase) else {
            dismiss()
            return
        }
        presenter.update(snapshot)
    }

    func dismiss() {
        presenter.dismiss()
        sessionID = nil
    }
}
