import AppKit
import Foundation
import SwiftUI

@MainActor
final class HomeController: ObservableObject {
    enum Page {
        case home
        case settings
    }

    enum Action: Equatable {
        case setGroup(String, Bool)
        case toggleGroup(String)
        case setAllLights(Bool)
        case toggleAllLights
        case doorUnlock
        case doorWaitAndUnlock
        case doorStatus
    }

    @Published var page: Page = .home
    @Published private(set) var isLaunching = true
    @Published private(set) var launchProgress = 0.0
    @Published private(set) var launchCompletedChecks = 0
    @Published private(set) var launchTotalChecks = 0
    @Published private(set) var isBusy = false
    @Published private(set) var activeAction: Action?
    @Published private(set) var completedAction: Action?
    @Published private(set) var languageCode = AppLanguage.current.rawValue
    @Published private(set) var statusText = L10n.text("Listo")
    @Published private(set) var statusIsError = false
    @Published private(set) var hasActionFeedback = false
    @Published private(set) var localNetworkReachable: Bool?
    @Published private(set) var lightsConfigurationLoaded = false
    @Published private(set) var lockConfigurationLoaded = false
    @Published private(set) var lightsConfigurationError: String?
    @Published private(set) var lockConfigurationError: String?
    @Published private(set) var lightGroups: [LightGroup] = []
    @Published private(set) var groupStates: [String: DevicePowerState] = [:]
    @Published private(set) var lightSettingsItems: [LightSettingsItem] = []
    @Published private(set) var lockTitle = L10n.text("Cerradura")
    @Published private(set) var lockIsOpen = false
    @Published private(set) var lockStateKnown = false
    @Published private(set) var lockStatus: TuyaLockStatus?
    @Published private(set) var configurationDocument = ConfigurationDocument()
    @Published private(set) var configurationStorageError: String?

    let doorbell = DoorbellService()
    var onDoorbellInteraction: (() -> Void)?
    private var notificationSessionID: UUID?

    private var lightsConfig: LightsConfiguration?
    private var lockClient: TuyaCloudClient?
    private var didBootstrap = false
    private var bootstrapTask: Task<Void, Never>?
    private var deviceChecksNeedRetry = false
    private var currentTask: Task<Void, Never>?
    private var feedbackDismissalTask: Task<Void, Never>?
    private var failedAction: Action?
    private var feedbackRevision = UUID()
    private var configurationRevision = UUID()

    var hasConfiguredDevices: Bool {
        !lightGroups.isEmpty || lockConfigurationLoaded
    }

    var allLightsState: DevicePowerState {
        let states = lightGroups.map { groupStates[$0.id] ?? .unknown }
        guard !states.isEmpty, !states.contains(.unknown) else { return .unknown }
        if states.allSatisfy({ $0 == .on }) { return .on }
        if states.allSatisfy({ $0 == .off }) { return .off }
        return .mixed
    }

    var allLightsStatusTitle: String {
        switch allLightsState {
        case .on: L10n.text(lightSettingsItems.count == 1 ? "Encendida" : "Encendidas")
        case .off: L10n.text(lightSettingsItems.count == 1 ? "Apagada" : "Apagadas")
        case .mixed: L10n.text("Estado mixto")
        case .unknown: L10n.text("Estado desconocido")
        }
    }

    var shouldShowStatusNotice: Bool {
        hasActionFeedback || (statusIsError && hasConfiguredDevices)
    }

    var canRetry: Bool {
        statusIsError && (failedAction != nil || localNetworkReachable == false || deviceChecksNeedRetry)
    }

    init() {
        doorbell.onChange = { [weak self] in self?.objectWillChange.send() }
        reloadConfiguration()
        launchTotalChecks = lightSettingsItems.count + (lockConfigurationLoaded ? 1 : 0)
    }

    func bootstrapIfNeeded() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        guard !didBootstrap else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            if let summary = await refreshDeviceStates(trackLaunchProgress: true) {
                applyDeviceCheckSummary(summary)
            }
            didBootstrap = true
            isLaunching = false
        }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
    }

    func reloadConfiguration() {
        guard !isBusy, bootstrapTask == nil else { return }
        dismissFeedback()
        configurationRevision = UUID()
        localNetworkReachable = nil

        do {
            try ConfigurationStore.prepare()
            configurationDocument = try ConfigurationStore.repository.document()
            configurationStorageError = nil
        } catch {
            configurationStorageError = error.localizedDescription
        }

        do {
            let configuration = try ConfigurationStore.loadLights()
            lightsConfig = configuration
            lightSettingsItems = configuration.lights.enumerated().map { index, light in
                LightSettingsItem(
                    id: light.id,
                    defaultLabel: light.displayName?.nonempty ?? L10n.format("Luz %@", String(index + 1)),
                    defaultGroup: light.group ?? ""
                )
            }
            rebuildGroups()
            groupStates = Dictionary(uniqueKeysWithValues: lightGroups.map { ($0.id, .unknown) })
            lightsConfigurationLoaded = true
            lightsConfigurationError = nil
        } catch {
            lightsConfig = nil
            lightSettingsItems = []
            lightGroups = []
            groupStates = [:]
            lightsConfigurationLoaded = false
            lightsConfigurationError = configurationMessage(error)
        }

        do {
            let configuration = try ConfigurationStore.loadLock()
            lockClient = TuyaCloudClient(config: configuration)
            lockTitle = configuration.displayName?.nonempty ?? L10n.text("Cerradura")
            lockConfigurationLoaded = true
            lockConfigurationError = nil
        } catch {
            lockClient = nil
            lockTitle = L10n.text("Cerradura")
            lockConfigurationLoaded = false
            lockConfigurationError = configurationMessage(error)
        }
        lockStateKnown = false
        lockStatus = nil
        if doorbell.settings.enabled { doorbell.restart(configuration: try? ConfigurationStore.loadLock()) }

        if let configurationStorageError {
            statusText = configurationStorageError
            statusIsError = true
            hasActionFeedback = true
        } else if lightsConfigurationError == nil && lockConfigurationError == nil && hasConfiguredDevices {
            statusText = L10n.text("Configuración lista")
            statusIsError = false
        } else if lightsConfigurationLoaded || lockConfigurationLoaded {
            statusText = L10n.text("Configuración parcial. Revisá Ajustes.")
            statusIsError = true
        } else {
            statusText = L10n.text("Agregá tus dispositivos desde Ajustes.")
            statusIsError = true
        }

        if didBootstrap && hasConfiguredDevices {
            Task {
                if let summary = await refreshDeviceStates() {
                    applyDeviceCheckSummary(summary)
                }
            }
        }
    }

    func startDoorbellService() {
        doorbell.configure()
        doorbell.notifications.onOpen = { [weak self] sessionID in
            guard let self else { return }
            notificationSessionID = sessionID
            run(.doorUnlock)
            notificationSessionID = nil
            onDoorbellInteraction?()
            NSApp.activate(ignoringOtherApps: true)
        }
        doorbell.restart(configuration: try? ConfigurationStore.loadLock())
    }

    func updateDoorbellSettings(_ settings: TuyaDoorbellSettings) {
        doorbell.update(settings, configuration: try? ConfigurationStore.loadLock())
    }

    private func configurationMessage(_ error: Error) -> String? {
        if let configurationError = error as? ConfigurationError, case .missingFile = configurationError {
            return nil
        }
        return error.localizedDescription
    }

    func languageDidChange() {
        languageCode = AppLanguage.current.rawValue
        reloadConfiguration()
    }

    func lightStatusTitle(for groupID: String, deviceCount: Int) -> String {
        switch groupStates[groupID] ?? .unknown {
        case .on:
            return L10n.text(deviceCount == 1 ? "Encendida" : "Encendidas")
        case .off:
            return L10n.text(deviceCount == 1 ? "Apagada" : "Apagadas")
        case .mixed:
            return L10n.text("Estado mixto")
        case .unknown:
            return L10n.text("Estado desconocido")
        }
    }

    func lightStatusColor(for groupID: String) -> Color {
        switch groupStates[groupID] ?? .unknown {
        case .on: .green
        case .off, .unknown: .secondary
        case .mixed: .orange
        }
    }

    var lockStatusTitle: String {
        guard lockStateKnown else {
            if let lockStatus, !lockStatus.reportsDoorPosition { return L10n.text("Sin sensor de puerta") }
            return L10n.text("Desconocido")
        }
        return L10n.text(lockIsOpen ? "Abierta" : "Cerrada")
    }

    func label(for id: String) -> String {
        lightSettingsItems.first(where: { $0.id == id })?.defaultLabel ?? ""
    }

    func group(for id: String) -> String {
        lightSettingsItems.first(where: { $0.id == id })?.defaultGroup ?? ""
    }

    func lockName() -> String {
        lockTitle
    }

    func saveDeviceLabels(_ updates: [DeviceLabelUpdate], lockName: String, lockGroup: String? = nil) -> Bool {
        saveConfiguration { try ConfigurationStore.repository.updateLabels(updates, lockName: lockName, lockGroup: lockGroup) }
    }

    func saveLight(_ setup: LightSetup) -> Bool {
        saveConfiguration { try ConfigurationStore.repository.saveLight(setup) }
    }

    func saveLock(_ setup: LockSetup) -> Bool {
        saveConfiguration { try ConfigurationStore.repository.saveLock(setup) }
    }

    func removeLight(id: String) -> Bool {
        saveConfiguration { try ConfigurationStore.repository.removeLight(id: id) }
    }

    func removeLock() -> Bool {
        saveConfiguration { try ConfigurationStore.repository.removeLock() }
    }

    func importConfiguration(at url: URL) -> Bool {
        saveConfiguration { try ConfigurationStore.repository.importEnvironment(at: url) }
    }

    private func saveConfiguration(_ update: () throws -> Void) -> Bool {
        guard !isBusy, !isLaunching, bootstrapTask == nil else { return false }
        do {
            try update()
            reloadConfiguration()
            return true
        } catch {
            statusText = error.localizedDescription
            statusIsError = true
            hasActionFeedback = true
            return false
        }
    }

    @discardableResult
    func run(_ action: Action) -> Bool {
        guard !isBusy, !isLaunching else { return false }
        if [.doorUnlock, .doorWaitAndUnlock].contains(action), !doorbell.canUnlock {
            dismissFeedback()
            statusText = L10n.text("No hay una solicitud vigente para abrir.")
            statusIsError = true
            hasActionFeedback = true
            return false
        }
        let requestedSessionID = notificationSessionID
        dismissFeedback()
        isBusy = true
        activeAction = action
        hasActionFeedback = true
        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.perform(action, sessionID: requestedSessionID)
        }
        return true
    }

    func cancelCurrentAction() {
        currentTask?.cancel()
    }

    func dismissFeedback() {
        feedbackDismissalTask?.cancel()
        feedbackDismissalTask = nil
        feedbackRevision = UUID()
        completedAction = nil
        failedAction = nil
        deviceChecksNeedRetry = false
        hasActionFeedback = false
        statusIsError = false
    }

    func retryLastAction() {
        guard !isBusy, canRetry else { return }
        if let failedAction {
            run(failedAction)
            return
        }
        dismissFeedback()
        isBusy = true
        hasActionFeedback = true
        statusText = L10n.text("Comprobando dispositivos…")
        currentTask = Task { [weak self] in
            guard let self else { return }
            let summary = await refreshDeviceStates()
            isBusy = false
            currentTask = nil
            if Task.isCancelled {
                statusText = L10n.text("Operación cancelada")
            } else if let summary {
                applyDeviceCheckSummary(summary)
            }
            if !statusIsError {
                scheduleFeedbackDismissal()
            }
        }
    }

    private func scheduleFeedbackDismissal() {
        feedbackDismissalTask?.cancel()
        feedbackDismissalTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard let self, !isBusy else { return }
            dismissFeedback()
        }
    }

    private func rebuildGroups() {
        guard let lights = lightsConfig?.lights else {
            lightGroups = []
            return
        }

        var groups: [LightGroup] = []
        for (index, light) in lights.enumerated() {
            let defaultLabel = lightSettingsItems[index].defaultLabel
            let label = defaultLabel.nonempty ?? L10n.format("Luz %@", String(index + 1))
            let groupName = light.group?.nonempty
            let id = groupName.map { "group:\($0.lowercased())" } ?? "device:\(light.id)"
            let title = groupName ?? label

            if let position = groups.firstIndex(where: { $0.id == id }) {
                let previous = groups[position]
                groups[position] = LightGroup(
                    id: previous.id,
                    title: previous.title,
                    lights: previous.lights + [light]
                )
            } else {
                groups.append(LightGroup(id: id, title: title, lights: [light]))
            }
        }
        lightGroups = groups
    }

    private func perform(_ action: Action, sessionID: UUID? = nil) async {
        var succeeded = false
        var retryAction = action
        defer {
            isBusy = false
            activeAction = nil
            currentTask = nil
            if statusIsError {
                failedAction = [.doorUnlock, .doorWaitAndUnlock].contains(action) ? nil : retryAction
            } else {
                completedAction = succeeded ? action : nil
                scheduleFeedbackDismissal()
            }
        }

        do {
            try Task.checkCancellation()
            switch action {
            case .toggleAllLights:
                statusText = L10n.text("Consultando todas las luces…")
                let states = try await currentLightStates()
                let on = !states.values.contains(true)
                retryAction = .setAllLights(on)
                statusText = L10n.text(on ? "Encendiendo todas las luces…" : "Apagando todas las luces…")
                try await setAllLights(on: on)
                statusText = L10n.text(on ? "Todas las luces encendidas" : "Todas las luces apagadas")
            case .setAllLights(let on):
                statusText = L10n.text(on ? "Encendiendo todas las luces…" : "Apagando todas las luces…")
                try await setAllLights(on: on)
                statusText = L10n.text(on ? "Todas las luces encendidas" : "Todas las luces apagadas")
            case .setGroup(let id, let on):
                let group = try group(with: id)
                groupStates[group.id] = .unknown
                statusText = on ? L10n.format("Encendiendo %@…", group.title) : L10n.format("Apagando %@…", group.title)
                try await set(group.lights, on: on)
                statusText = on ? L10n.format("%@: encendido", group.title) : L10n.format("%@: apagado", group.title)
                groupStates[group.id] = on ? .on : .off
                localNetworkReachable = true
            case .toggleGroup(let id):
                let group = try group(with: id)
                groupStates[group.id] = .unknown
                guard let first = group.lights.first, let config = lightsConfig else {
                    throw ConfigurationError.invalid(L10n.text("No hay dispositivos en este grupo."))
                }
                statusText = L10n.format("Consultando %@…", group.title)
                let client = TuyaLANClient(config: first)
                let response = try await client.status()
                guard let current = client.switchValue(from: response, dpid: config.tuyaSwitchDPID) else {
                    throw TuyaLANError.invalidPacket(L10n.text("No se encontró el DPID configurado"))
                }
                try await set(group.lights, on: !current)
                groupStates[group.id] = current ? .off : .on
                localNetworkReachable = true
                statusText = current ? L10n.format("%@: apagado", group.title) : L10n.format("%@: encendido", group.title)
            case .doorUnlock, .doorWaitAndUnlock:
                let sessionAvailable = doorbell.macSession.beginInteraction()
                guard let lockClient, let coordinator = doorbell.coordinator,
                      let authorization = await coordinator.reserveUnlock(
                        sessionID: sessionID, sessionAvailable: sessionAvailable) else {
                    throw TuyaCloudAPIError(message: "No hay una solicitud vigente o la sesión de macOS no está disponible.")
                }
                lockStateKnown = false
                await doorbell.refresh()
                statusText = L10n.text("Enviando…")
                do {
                    let accepted = try await lockClient.unlock {
                        let available = await MainActor.run {
                            self.doorbell.coordinator === coordinator && self.doorbell.settings.enabled
                                && self.doorbell.macSession.isAvailable()
                        }
                        return await coordinator.authorizeSend(sessionID: authorization, sessionAvailable: available)
                    }
                    await coordinator.completeUnlock(sessionID: authorization, accepted: accepted)
                    statusIsError = !accepted
                } catch {
                    await coordinator.completeUnlock(sessionID: authorization, accepted: nil)
                    await doorbell.refresh()
                    statusText = L10n.text("Estado no confirmado")
                    statusIsError = true
                    return
                }
                await doorbell.refresh()
                statusText = doorbell.statusTitle
            case .doorStatus:
                guard let lockClient else { throw ConfigurationError.missingFile }
                statusText = L10n.format("Consultando %@…", lockTitle)
                let deviceStatus = try await lockClient.status()
                applyLockStatus(deviceStatus)
                statusText = L10n.format("%@: %@", lockTitle, lockStatusTitle)
                if let battery = deviceStatus.batteryPercentage {
                    statusText += " · " + L10n.format("Batería: %@%%", String(battery))
                }
            }
            succeeded = !statusIsError
        } catch is CancellationError {
            statusText = L10n.text("Operación cancelada")
            statusIsError = false
        } catch {
            statusText = Task.isCancelled ? L10n.text("Operación cancelada") : error.localizedDescription
            statusIsError = !Task.isCancelled
        }
    }

    private func group(with id: String) throws -> LightGroup {
        guard let group = lightGroups.first(where: { $0.id == id }) else {
            throw ConfigurationError.invalid(L10n.text("No se encontró el grupo de luces."))
        }
        return group
    }

    private func setAllLights(on: Bool) async throws {
        guard let config = lightsConfig, !config.lights.isEmpty else {
            throw ConfigurationError.invalid(L10n.text("Todavía no hay luces disponibles"))
        }
        let groups = lightGroups
        groupStates = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, .unknown) })
        let confirmed = await withTaskGroup(of: (String, Bool).self, returning: Set<String>.self) { taskGroup in
            for light in config.lights {
                taskGroup.addTask {
                    do {
                        try Task.checkCancellation()
                        try await TuyaLANClient(config: light).setStatus(on, dpid: config.tuyaSwitchDPID)
                        return (light.id, true)
                    } catch {
                        return (light.id, false)
                    }
                }
            }
            var confirmed: Set<String> = []
            for await (id, succeeded) in taskGroup {
                if succeeded { confirmed.insert(id) }
            }
            return confirmed
        }
        for group in groups where group.lights.allSatisfy({ confirmed.contains($0.id) }) {
            groupStates[group.id] = on ? .on : .off
        }
        localNetworkReachable = !confirmed.isEmpty
        try Task.checkCancellation()
        let failedCount = config.lights.count - confirmed.count
        guard failedCount == 0 else {
            throw ConfigurationError.invalid(L10n.format("No respondieron %@ de %@ luces. Podés reintentar.", String(failedCount), String(config.lights.count)))
        }
    }

    private func currentLightStates() async throws -> [String: Bool] {
        guard let config = lightsConfig, !config.lights.isEmpty else {
            throw ConfigurationError.invalid(L10n.text("Todavía no hay luces disponibles"))
        }
        let states = await withTaskGroup(of: (String, Bool?).self, returning: [String: Bool].self) { taskGroup in
            for light in config.lights {
                taskGroup.addTask {
                    let client = TuyaLANClient(config: light, timeout: 3)
                    let response = try? await client.status()
                    return (light.id, response.flatMap { client.switchValue(from: $0, dpid: config.tuyaSwitchDPID) })
                }
            }
            var states: [String: Bool] = [:]
            for await (id, state) in taskGroup {
                if let state { states[id] = state }
            }
            return states
        }
        try Task.checkCancellation()
        applyLightStates(states)
        localNetworkReachable = !states.isEmpty
        let failedCount = config.lights.count - states.count
        guard failedCount == 0 else {
            throw ConfigurationError.invalid(L10n.format("No se pudo consultar %@ de %@ luces. Podés reintentar.", String(failedCount), String(config.lights.count)))
        }
        return states
    }

    private func set(_ lights: [LightConfiguration], on: Bool) async throws {
        guard let dpid = lightsConfig?.tuyaSwitchDPID else {
            throw ConfigurationError.missingFile
        }
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            for light in lights {
                taskGroup.addTask {
                    try await TuyaLANClient(config: light).setStatus(on, dpid: dpid)
                }
            }
            try await taskGroup.waitForAll()
        }
    }

    private enum DeviceCheckResult: Sendable {
        case light(String, Bool?)
        case lock(TuyaLockStatus?, Bool)
    }

    private struct DeviceCheckSummary {
        let totalCount: Int
        let failedCount: Int
    }

    private func refreshDeviceStates(trackLaunchProgress: Bool = false) async -> DeviceCheckSummary? {
        let configurationSnapshot = configurationRevision
        let feedbackSnapshot = feedbackRevision
        let lights = lightsConfig?.lights ?? []
        let dpid = lightsConfig?.tuyaSwitchDPID ?? 1
        let lock = lockClient
        let totalCount = lights.count + (lock == nil ? 0 : 1)
        var deviceStates: [String: Bool] = [:]
        var completedCount = 0
        var failedCount = 0

        if trackLaunchProgress {
            launchTotalChecks = totalCount
            launchCompletedChecks = 0
            launchProgress = totalCount == 0 ? 1 : 0
        }
        guard totalCount > 0 else { return nil }

        await withTaskGroup(of: DeviceCheckResult.self) { taskGroup in
            for light in lights {
                taskGroup.addTask {
                    let client = TuyaLANClient(config: light, timeout: 3)
                    let response = try? await client.status()
                    return .light(light.id, response.flatMap { client.switchValue(from: $0, dpid: dpid) })
                }
            }
            if let lock {
                taskGroup.addTask {
                    do {
                        let response = try await lock.status()
                        return .lock(response, true)
                    } catch {
                        return .lock(nil, false)
                    }
                }
            }
            for await result in taskGroup {
                guard configurationSnapshot == configurationRevision, feedbackSnapshot == feedbackRevision else { continue }
                switch result {
                case .light(let id, let state):
                    if let state {
                        deviceStates[id] = state
                    } else {
                        failedCount += 1
                    }
                    applyLightStates(deviceStates)
                    localNetworkReachable = !deviceStates.isEmpty
                case .lock(let state, let succeeded):
                    applyLockStatus(state)
                    if !succeeded { failedCount += 1 }
                }
                completedCount += 1
                if trackLaunchProgress {
                    launchCompletedChecks = completedCount
                    launchProgress = Double(completedCount) / Double(totalCount)
                }
            }
        }
        guard configurationSnapshot == configurationRevision, feedbackSnapshot == feedbackRevision else { return nil }
        return DeviceCheckSummary(totalCount: totalCount, failedCount: failedCount)
    }

    private func applyDeviceCheckSummary(_ summary: DeviceCheckSummary) {
        deviceChecksNeedRetry = summary.failedCount > 0
        statusIsError = deviceChecksNeedRetry
        if deviceChecksNeedRetry {
            statusText = L10n.format("No se pudo consultar %@ de %@ dispositivos. Podés reintentar.", String(summary.failedCount), String(summary.totalCount))
        } else {
            statusText = L10n.text("Dispositivos comprobados")
        }
    }

    private func applyLightStates(_ deviceStates: [String: Bool]) {
        var updatedStates: [String: DevicePowerState] = [:]
        for group in lightGroups {
            let states = group.lights.compactMap { deviceStates[$0.id] }
            guard states.count == group.lights.count, let first = states.first else {
                updatedStates[group.id] = .unknown
                continue
            }
            updatedStates[group.id] = states.allSatisfy { $0 == first } ? (first ? .on : .off) : .mixed
        }
        groupStates = updatedStates
    }

    private func applyLockStatus(_ status: TuyaLockStatus?) {
        lockStatus = status
        lockStateKnown = status?.doorIsOpen != nil
        lockIsOpen = status?.doorIsOpen ?? false
    }
}

private extension String {
    var nonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
