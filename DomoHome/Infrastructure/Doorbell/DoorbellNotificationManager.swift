import AppKit
import UserNotifications

@MainActor
final class DoorbellNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let categoryID = "domohome.doorbell"
    private var activeIdentifiers: Set<String> = []
    var onOpen: ((UUID) -> Void)?
    var onIgnore: ((UUID) -> Void)?
    var onPermission: ((String) -> Void)?

    func configure() {
        center.delegate = self
        let open = UNNotificationAction(identifier: "open", title: L10n.text("Abrir"), options: [.foreground])
        let ignore = UNNotificationAction(identifier: "ignore", title: L10n.text("Ignorar"), options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: categoryID, actions: [open, ignore], intentIdentifiers: [], options: [.customDismissAction])])
        refreshPermission()
    }

    func requestPermission() {
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            refreshPermission()
        }
    }

    func refreshPermission() {
        Task {
            let settings = await center.notificationSettings()
            let status: String
            switch settings.authorizationStatus {
            case .authorized, .provisional: status = "Permitidas"
            case .denied: status = "Denegadas"
            default: status = "Sin solicitar"
            }
            onPermission?(status)
        }
    }

    func notify(sessionID: UUID, validate: () async -> Bool) async -> Bool {
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional].contains(settings.authorizationStatus),
              !Task.isCancelled, await validate() else { return false }
        let content = UNMutableNotificationContent()
        content.title = L10n.text("DomoHome — Llaman a la puerta")
        content.body = L10n.text("La cerradura recibió una llamada.")
        content.categoryIdentifier = categoryID
        content.sound = .default
        content.userInfo = ["sessionID": sessionID.uuidString]
        let identifier = "doorbell-" + sessionID.uuidString
        activeIdentifiers.insert(identifier)
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            guard !Task.isCancelled, await validate() else {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
                activeIdentifiers.remove(identifier)
                return false
            }
            return true
        } catch { return false }
    }

    func clear() {
        let identifiers = Array(activeIdentifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        activeIdentifiers.removeAll()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.content.userInfo["sessionID"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            guard let identifier, let sessionID = UUID(uuidString: identifier) else { return }
            if action == "open" { onOpen?(sessionID) }
            else if action == "ignore" || action == UNNotificationDismissActionIdentifier { onIgnore?(sessionID) }
        }
    }
}

@MainActor
final class MacSessionAvailability {
    private(set) var available = false
    private let sessionCheck: (() -> Bool)?
    private let uptime: () -> TimeInterval
    private var authorizationDeadline: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    var onUnavailable: (() -> Void)?

    init(sessionCheck: (() -> Bool)? = nil, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.sessionCheck = sessionCheck
        self.uptime = uptime
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.invalidate()
                }
            })
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            distributedObservers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.invalidate()
                }
            })
        }
    }

    func beginInteraction() -> Bool {
        available = false
        guard sessionIsOnConsole() else { return false }
        authorizationDeadline = uptime() + 30
        available = true
        return true
    }

    func invalidate() {
        available = false
        authorizationDeadline = 0
        onUnavailable?()
    }

    func isAvailable() -> Bool {
        available && uptime() < authorizationDeadline && sessionIsOnConsole()
    }

    func sessionIsOnConsole() -> Bool {
        if let sessionCheck { return sessionCheck() }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool != true
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }
}
