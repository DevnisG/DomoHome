import AppKit
import ServiceManagement

@MainActor
protocol LoginItemServicing {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    func openSettings()
}

@MainActor
private struct MainAppLoginService: LoginItemServicing {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() async throws { try await SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?
    private let service: any LoginItemServicing
    private let bundleURL: URL
    private var observer: NSObjectProtocol?

    init(service: (any LoginItemServicing)? = nil, bundleURL: URL = Bundle.main.bundleURL) {
        self.service = service ?? MainAppLoginService()
        self.bundleURL = bundleURL
        refreshStatus()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshStatus() }
            }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false; refreshStatus() }
        errorMessage = nil
        if enabled && !Self.isInstalled(bundleURL) {
            errorMessage = "Mové DomoHome a Aplicaciones y abrila desde ahí para activar el inicio automático."
            return
        }
        do {
            if enabled {
                switch service.status {
                case .enabled: return
                case .requiresApproval: service.openSettings(); return
                default: try service.register()
                }
            } else if service.status != .notRegistered {
                try await service.unregister()
            }
        } catch {
            if service.status != .requiresApproval {
                errorMessage = "No se pudo actualizar el inicio de sesión."
            }
        }
    }

    func refreshStatus() {
        let status = service.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func openSettings() { service.openSettings() }

    static func isInstalled(_ url: URL) -> Bool {
        let parent = url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL
        return [URL(fileURLWithPath: "/Applications"),
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            .contains { parent == $0.resolvingSymlinksInPath().standardizedFileURL }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
