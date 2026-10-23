import Foundation

struct DoorbellSnapshot: Equatable, Sendable {
    enum Phase: String, Sendable {
        case idle, ringing, available, unlocking, accepted, reported, closed, expired, failed, unknown
    }

    var phase: Phase = .idle
    var sessionID: UUID?
    var remainingSeconds = 0
    var canUnlock: Bool { phase == .available && remainingSeconds > 0 }
}

struct DoorbellClock: Sendable {
    var wall: @Sendable () -> Date = { Date() }
    private static let origin = ContinuousClock.now
    var monotonic: @Sendable () -> TimeInterval = { uptime() }

    static func uptime() -> TimeInterval {
        let duration = origin.duration(to: ContinuousClock.now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
}

actor TuyaDoorbellCoordinator {
    private let deviceID: String
    private let settings: TuyaDoorbellSettings
    private let clock: DoorbellClock
    private var snapshot = DoorbellSnapshot()
    private var metrics = DoorbellMetrics()
    private var deadline: TimeInterval = 0
    private var wallDeadline = Date.distantPast
    private var seen: [String: TimeInterval] = [:]
    private var lastPropertyTime: [Int: Int64] = [:]
    private var minimumEventDate: Date
    private var consumed = false
    private var sent = false
    private var notified = false
    private var attemptDate: Date?
    private var attemptSession: UUID?
    private var ignored = false
    private var windowEnded = false
    private var sessionExpiry: TimeInterval = 0
    private var connected = false

    init(deviceID: String, settings: TuyaDoorbellSettings, clock: DoorbellClock = DoorbellClock()) {
        self.deviceID = deviceID
        self.settings = settings
        self.clock = clock
        minimumEventDate = clock.wall()
    }

    func diagnostics() -> DoorbellMetrics { metrics }

    func recordNotification(eventDate: Date) {
        metrics.recordNotification(event: eventDate, delivered: clock.wall())
    }

    func current() -> DoorbellSnapshot {
        expireIfNeeded()
        return snapshot
    }

    func invalidate(disconnect: Bool = true) {
        if disconnect { connected = false }
        minimumEventDate = clock.wall()
        deadline = 0
        wallDeadline = .distantPast
        snapshot.remainingSeconds = 0
        if snapshot.sessionID != nil { snapshot.phase = .closed }
    }

    @discardableResult
    func receive(_ event: TuyaMessage) -> UUID? {
        guard settings.enabled, event.schemaVersion == 1 else { return nil }
        if event.type == "diagnostic", event.state == TuyaMessageError.decodingFailure.rawValue {
            invalidate(disconnect: false)
            return nil
        }
        if event.type == "connection" {
            if event.state == "connected", event.environment == settings.environment.rawValue {
                connected = true
            } else {
                invalidate()
            }
            return nil
        }
        guard connected, event.type == "property", event.deviceId == deviceID,
              let dp = event.dpId, let code = event.code, let value = event.value,
              [(19, "doorbell"), (9, "unlock_request"), (15, "unlock_app")].contains(where: { $0.0 == dp && $0.1 == code }),
              let timestamp = event.eventTimeMs, let published = event.publishedDate,
              let messageID = event.messageId, !messageID.isEmpty, messageID.count <= 256,
              let dataID = event.dataId, !dataID.isEmpty, dataID.count <= 256 else { return nil }
        let now = clock.wall()
        let eventDate = Date(timeIntervalSince1970: Double(timestamp) / 1000)
        guard eventDate >= minimumEventDate,
              now.timeIntervalSince(eventDate) <= settings.maxEventAge,
              eventDate.timeIntervalSince(now) <= settings.maxClockSkew,
              now.timeIntervalSince(published) <= settings.maxEventAge,
              published.timeIntervalSince(now) <= settings.maxClockSkew,
              eventDate.timeIntervalSince(published) <= settings.maxClockSkew else { return nil }
        let monotonic = clock.monotonic()
        seen = seen.filter { monotonic - $0.value < 300 }
        let keys = ["m:\(messageID):\(dp)", "d:\(dataID):\(dp):\(timestamp)"]
        guard !keys.contains(where: { seen[$0] != nil }), timestamp > (lastPropertyTime[dp] ?? 0) else { return nil }
        if seen.count > 2048 { return nil }
        keys.forEach { seen[$0] = monotonic }
        lastPropertyTime[dp] = timestamp
        metrics.recordEvent(event: eventDate, published: published, received: now)
        expireIfNeeded()
        if dp == 19, value.isTrue {
            guard !(consumed || ignored) || windowEnded else { return nil }
            if snapshot.sessionID == nil || windowEnded || [.closed, .expired, .idle].contains(snapshot.phase) {
                beginSession()
                snapshot.phase = .ringing
            }
            guard !notified, !ignored else { return nil }
            notified = true
            return snapshot.sessionID
        }
        if dp == 9, let seconds = value.integer, (0...120).contains(seconds) {
            if seconds == 0 {
                windowEnded = true
                deadline = 0
                wallDeadline = .distantPast
                snapshot.remainingSeconds = 0
                snapshot.phase = .closed
            } else {
                guard !(consumed || ignored) || windowEnded else { return nil }
                let remaining = Double(seconds) - max(0, now.timeIntervalSince(eventDate)) - settings.maxClockSkew
                guard remaining > 0 else { return nil }
                if snapshot.sessionID == nil || windowEnded || [.closed, .expired, .idle].contains(snapshot.phase) {
                    beginSession()
                }
                guard !consumed, !ignored else { return nil }
                let proposed = monotonic + remaining
                deadline = deadline > 0 ? min(deadline, proposed) : proposed
                wallDeadline = min(wallDeadline == .distantPast ? now.addingTimeInterval(remaining) : wallDeadline,
                                   now.addingTimeInterval(remaining))
                sessionExpiry = deadline
                snapshot.phase = .available
                snapshot.remainingSeconds = max(0, Int(deadline - monotonic))
            }
        }
        if dp == 15, value.integer == 1, let attemptDate,
           attemptSession == snapshot.sessionID,
           now.timeIntervalSince(attemptDate) >= 0, now.timeIntervalSince(attemptDate) <= 15,
           eventDate >= attemptDate {
            snapshot.phase = .reported
            snapshot.remainingSeconds = 0
            deadline = 0
        }
        return nil
    }

    func reserveUnlock(sessionID: UUID? = nil, sessionAvailable: Bool) -> UUID? {
        expireIfNeeded()
        guard settings.enabled, connected, sessionAvailable, snapshot.canUnlock, !consumed, !ignored,
              sessionID == nil || sessionID == snapshot.sessionID,
              let id = snapshot.sessionID else { return nil }
        consumed = true
        snapshot.phase = .unlocking
        attemptDate = clock.wall()
        attemptSession = id
        return id
    }

    func authorizeSend(sessionID: UUID, sessionAvailable: Bool) -> Bool {
        expireIfNeeded()
        guard settings.enabled, connected, sessionAvailable, consumed, !sent, attemptSession == sessionID,
              snapshot.sessionID == sessionID, snapshot.phase == .unlocking,
              deadline > clock.monotonic(), wallDeadline > clock.wall() else { return false }
        sent = true
        return true
    }

    func completeUnlock(sessionID: UUID, accepted: Bool?) {
        guard snapshot.sessionID == sessionID, attemptSession == sessionID, snapshot.phase != .reported else { return }
        snapshot.phase = accepted == true ? .accepted : (accepted == false ? .failed : .unknown)
        snapshot.remainingSeconds = 0
    }

    func ignore(sessionID: UUID) {
        guard snapshot.sessionID == sessionID else { return }
        ignored = true
        deadline = 0
        snapshot.remainingSeconds = 0
        snapshot.phase = .closed
    }

    private func beginSession() {
        snapshot = DoorbellSnapshot(sessionID: UUID())
        consumed = false
        sent = false
        notified = false
        ignored = false
        windowEnded = false
        sessionExpiry = clock.monotonic() + 120
        deadline = 0
        wallDeadline = .distantPast
    }

    private func expireIfNeeded() {
        if sessionExpiry > 0, clock.monotonic() >= sessionExpiry {
            windowEnded = true
            if snapshot.phase == .ringing { snapshot.phase = .expired }
        }
        guard deadline > 0 else { return }
        let remaining = min(deadline - clock.monotonic(), wallDeadline.timeIntervalSince(clock.wall()))
        snapshot.remainingSeconds = max(0, Int(remaining))
        if remaining <= 0 {
            deadline = 0
            if snapshot.phase == .available { snapshot.phase = .expired }
            if snapshot.phase == .unlocking { snapshot.phase = .unknown }
        }
    }
}
