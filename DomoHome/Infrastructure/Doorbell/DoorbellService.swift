import AppKit
import Foundation

@MainActor
final class DoorbellService {
    private(set) var settings = TuyaDoorbellSettings()
    private(set) var snapshot = DoorbellSnapshot()
    private(set) var connectionState = "disabled"
    private(set) var notificationPermission = "Sin solicitar"
    private(set) var metrics = DoorbellMetrics()
    private var notificationTask: Task<Void, Never>?
    private(set) var lastEvent: Date?
    private(set) var coordinator: TuyaDoorbellCoordinator?
    let alert = DoorbellAlertPresenter()
    private lazy var alertDelivery = DoorbellAlertDelivery(presenter: alert)
    let notifications = DoorbellNotificationManager()
    let macSession = MacSessionAvailability()
    var onChange: (() -> Void)?
    private var activeConfiguration: LockConfiguration?
    private var stream: (any TuyaMessageStream)?
    private var streamTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var revision = UUID()
    private var configured = false
    private var activity: NSObjectProtocol?

    var canUnlock: Bool { settings.enabled && snapshot.canUnlock && connectionState == "connected" }

    var statusTitle: String {
        switch snapshot.phase {
        case .idle: L10n.text("Sin solicitud")
        case .ringing: L10n.text("Llamando")
        case .available: L10n.format("Disponible para abrir (%@s)", String(snapshot.remainingSeconds))
        case .unlocking: L10n.text("Enviando…")
        case .accepted: L10n.text("Solicitud enviada")
        case .reported: L10n.text("Apertura reportada")
        case .closed: L10n.text("Solicitud cerrada")
        case .expired: L10n.text("Solicitud vencida")
        case .failed: L10n.text("No se pudo enviar la solicitud")
        case .unknown: L10n.text("Estado no confirmado")
        }
    }

    func configure() {
        guard !configured else { return }
        configured = true
        notifications.onPermission = { [weak self] status in
            self?.notificationPermission = status
            self?.onChange?()
        }
        notifications.onIgnore = { [weak self] sessionID in
            guard let self, let coordinator else { return }
            Task {
                await coordinator.ignore(sessionID: sessionID)
                await self.refresh()
                self.notifications.clear()
            }
        }
        macSession.onUnavailable = { [weak self] in
            guard let self, let coordinator else { return }
            Task {
                await coordinator.invalidate(disconnect: false)
                await self.refresh()
                self.notifications.clear()
            }
        }
        alert.onOpen = { [weak self] id in self?.notifications.onOpen?(id) }
        alert.onIgnore = { [weak self] id in self?.notifications.onIgnore?(id) }
        notifications.configure()
    }

    func update(_ settings: TuyaDoorbellSettings, configuration: LockConfiguration?) {
        let restartRequired = self.settings.enabled != settings.enabled
            || self.settings.environment != settings.environment
            || self.settings.maxEventAge != settings.maxEventAge
            || self.settings.maxClockSkew != settings.maxClockSkew
        settings.save()
        self.settings = settings
        if restartRequired { restart(configuration: configuration, force: true) }
        if !settings.notificationsEnabled {
            notificationTask?.cancel()
            alertDelivery.dismiss()
            notifications.clear()
        }
        notifications.refreshPermission()
        onChange?()
    }

    func restart(configuration: LockConfiguration?, injectedStream: (any TuyaMessageStream)? = nil, force: Bool = false) {
        if !force, injectedStream == nil, stream != nil, ["connected", "connecting"].contains(connectionState),
           let activeConfiguration, let configuration,
           activeConfiguration.tuyaClientID == configuration.tuyaClientID,
           activeConfiguration.tuyaClientSecret == configuration.tuyaClientSecret,
           activeConfiguration.tuyaAPIHost == configuration.tuyaAPIHost,
           activeConfiguration.lockDeviceID == configuration.lockDeviceID { return }
        stop()
        guard configured, settings.enabled else { return }
        guard let configuration else {
            connectionState = TuyaMessageError.configurationMissing.rawValue
            onChange?()
            return
        }
        let currentRevision = UUID()
        revision = currentRevision
        let coordinator = TuyaDoorbellCoordinator(deviceID: configuration.lockDeviceID, settings: settings)
        self.coordinator = coordinator
        activeConfiguration = configuration
        let stream = injectedStream ?? TuyaMessageProcessAdapter(configuration: configuration, settings: settings)
        self.stream = stream
        connectionState = "connecting"
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Receive doorbell messages")
        streamTask = Task { [weak self] in
            for await event in stream.messages() {
                guard let self, revision == currentRevision, !Task.isCancelled else { return }
                let notificationID = await coordinator.receive(event)
                guard revision == currentRevision else { return }
                if event.type == "connection" { connectionState = event.state ?? "disconnected" }
                if event.type == "property" { lastEvent = Date() }
                await refresh()
                if let notificationID, alertDelivery.receiveCall(snapshot, enabled: settings.notificationsEnabled) {
                    notificationTask?.cancel()
                    notificationTask = Task {
                        let delivered = await self.notifications.notify(sessionID: notificationID) {
                            let state = await coordinator.current()
                            return self.revision == currentRevision && self.settings.notificationsEnabled && state.sessionID == notificationID
                                && ![.closed, .expired].contains(state.phase)
                        }
                        if delivered, let timestamp = event.eventTimeMs {
                            await coordinator.recordNotification(eventDate: Date(timeIntervalSince1970: Double(timestamp) / 1000))
                            await self.refresh()
                        }
                    }
                }
            }
            guard let self, revision == currentRevision else { return }
            await coordinator.invalidate()
            connectionState = "disconnected"
            await refresh()
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, revision == currentRevision else { return }
                await refresh()
            }
        }
        onChange?()
    }

    func refresh() async {
        guard let coordinator else { return }
        let currentRevision = revision
        let next = await coordinator.current()
        guard currentRevision == revision else { return }
        snapshot = next
        alertDelivery.update(next)
        metrics = await coordinator.diagnostics()
        if [.closed, .expired].contains(snapshot.phase) { notifications.clear() }
        onChange?()
    }

    func stop() {
        revision = UUID()
        alertDelivery.dismiss()
        streamTask?.cancel()
        notificationTask?.cancel()
        notificationTask = nil
        ticker?.cancel()
        stream?.stop()
        stream = nil
        streamTask = nil
        ticker = nil
        if let coordinator { Task { await coordinator.invalidate() } }
        coordinator = nil
        activeConfiguration = nil
        snapshot = DoorbellSnapshot()
        lastEvent = nil
        metrics = DoorbellMetrics()
        connectionState = "disabled"
        notifications.clear()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        onChange?()
    }
}
