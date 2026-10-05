import AppKit
import SwiftUI

struct ContentView: View {
    let appDelegate: AppDelegate

    @EnvironmentObject private var controller: HomeController
    @EnvironmentObject private var shortcutManager: GlobalShortcutManager
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppLanguage.preferenceKey) private var languageCode = AppLanguage.spanish.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var launchLogoVisible = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.blue.opacity(0.17),
                    Color(nsColor: .windowBackgroundColor),
                    Color.cyan.opacity(0.09)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .padding(.bottom, 18)

                if controller.shouldShowStatusNotice {
                    statusPanel
                        .padding(.horizontal, 28)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }

                if controller.page == .home {
                    homePage
                } else {
                    SettingsView()
                }

                footer
            }
            .allowsHitTesting(!controller.isLaunching)
            .accessibilityHidden(controller.isLaunching)

            if controller.isLaunching {
                launchScreen
                    .transition(.opacity)
            }
        }
        .frame(width: 780, height: 520)
        .task {
            await animateLaunch()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controller.shouldShowStatusNotice)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controller.isLaunching)
        .onChange(of: languageCode) { _, _ in
            controller.languageDidChange()
        }
        .onAppear {
            appDelegate.configure(
                controller: controller,
                shortcutManager: shortcutManager,
                openControlPanel: { openWindow(id: "controlPanel") }
            )
        }
    }

    private var launchScreen: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [.blue.opacity(0.14), .clear, .cyan.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 16) {
                Image("AppBrandMark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .scaleEffect(reduceMotion ? 1 : (launchLogoVisible ? 1 : 0.92))
                    .opacity(launchLogoVisible ? 1 : 0.6)
                    .shadow(color: .cyan.opacity(launchLogoVisible ? 0.24 : 0.04), radius: 24)
                Text("DomoHome")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .opacity(launchLogoVisible ? 1 : 0.6)
                ProgressView(value: controller.launchProgress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(.primary.opacity(0.65))
                    .frame(width: 156)
                    .padding(.top, 4)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controller.launchProgress)
                    .accessibilityLabel(L10n.text("Preparando dispositivos"))
                    .accessibilityValue(L10n.format("%@ de %@ dispositivos comprobados", String(controller.launchCompletedChecks), String(controller.launchTotalChecks)))
                Text(L10n.format("%@ de %@ dispositivos comprobados", String(controller.launchCompletedChecks), String(controller.launchTotalChecks)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Iniciando DomoHome"))
    }

    private func animateLaunch() async {
        guard controller.isLaunching else { return }
        withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.65)) {
            launchLogoVisible = true
        }
        await controller.bootstrapIfNeeded()
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image("AppBrandMark")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 7) {
                Text("DomoHome")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                connectionBadge
            }

            Spacer()

            HStack(spacing: 4) {
                MenuBarView(appDelegate: appDelegate)
                    .id(languageCode)
                    .frame(width: 38, height: 36)
                    .accessibilityLabel(L10n.text("Acciones rápidas"))

                navigationButton(L10n.text("Inicio"), icon: "square.grid.2x2.fill", page: .home)
                navigationButton(L10n.text("Ajustes"), icon: "slider.horizontal.3", page: .settings)
            }
            .padding(4)
            .glassSurface(cornerRadius: 13)
        }
        .padding(12)
        .glassSurface(cornerRadius: 22, tint: .cyan, glow: 0.12)
    }

    private func navigationButton(_ title: String, icon: String, page: HomeController.Page) -> some View {
        Button {
            controller.page = page
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    controller.page == page ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 9)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(controller.page == page ? .isSelected : [])
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controller.page)
    }

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(controller.localNetworkReachable.map { $0 ? Color.mint : .orange } ?? .secondary)
                .frame(width: 5, height: 5)
            Text(L10n.text(controller.localNetworkReachable.map { $0 ? "Red local" : "Sin conexión local" } ?? "Comprobando conexión…"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.primary.opacity(0.035), in: Capsule())
        .overlay(Capsule().strokeBorder(.cyan.opacity(0.16), lineWidth: 0.5))
        .help(L10n.text(controller.localNetworkReachable == true ? "Red local disponible" : "Red local"))
    }

    private var homePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !controller.hasConfiguredDevices {
                    welcomeState
                } else {
                    if controller.lightGroups.isEmpty {
                        HStack {
                            Text(L10n.text("Dispositivos"))
                                .font(.title3.bold())
                            Spacer()
                            Text(L10n.format("%@ configurados", String(controller.lightSettingsItems.count + (controller.lockConfigurationLoaded ? 1 : 0))))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                controller.reloadConfiguration()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.text("Recargar"))
                            .help(L10n.text("Recargar"))
                            .disabled(controller.isBusy)
                        }
                        .padding(.horizontal, 2)
                        emptyState
                    } else {
                        allLightsCard
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            ForEach(controller.lightGroups) { group in
                                lightCard(group)
                            }
                        }
                    }

                    if controller.lockConfigurationLoaded {
                        lockCard
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    private var statusPanel: some View {
        HStack(spacing: 9) {
            if controller.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: controller.statusIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(controller.statusIsError ? .orange : .green)
                    .font(.subheadline)
            }
            Text(controller.statusText)
                .font(.caption)
                .lineLimit(3)
            Spacer(minLength: 8)
            if controller.isBusy {
                Button(L10n.text("Cancelar")) { controller.cancelCurrentAction() }
                    .controlSize(.small)
            } else {
                if controller.statusIsError {
                    if controller.canRetry {
                        Button(L10n.text("Reintentar")) { controller.retryLastAction() }
                            .controlSize(.small)
                    } else {
                        Button(L10n.text("Ir a Ajustes")) { controller.page = .settings }
                            .controlSize(.small)
                    }
                }
                Button {
                    controller.dismissFeedback()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.text("Cerrar aviso"))
                .help(L10n.text("Cerrar aviso"))
            }
        }
        .padding(10)
        .glassSurface(cornerRadius: 12, tint: controller.statusIsError ? .orange : .cyan)
    }

    private var welcomeState: some View {
        VStack(spacing: 18) {
            Image("AppBrandMark")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 64, height: 64)
                .shadow(color: .cyan.opacity(0.12), radius: 16)
            VStack(spacing: 8) {
                Text(L10n.text("Bienvenido a DomoHome"))
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                Text(L10n.text("Configurá tu primer dispositivo para empezar."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                Label(L10n.text("Luces"), systemImage: "sun.max.fill")
                Label(L10n.text("Cerradura"), systemImage: "lock.fill")
                Label(L10n.text("Atajos de teclado"), systemImage: "keyboard")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Button(L10n.text("Configurar dispositivos"), systemImage: "slider.horizontal.3") {
                controller.page = .settings
            }
            .controlSize(.large)
            .glassActionStyle(prominent: true)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .glassSurface(cornerRadius: 22, glow: 0.25)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lightbulb")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(L10n.text("Todavía no hay luces disponibles"))
                .font(.headline)
            Text(L10n.text("Cargá una configuración para empezar."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(L10n.text("Ir a Ajustes")) { controller.page = .settings }
                .glassActionStyle(prominent: true)
        }
        .frame(maxWidth: .infinity)
        .padding(26)
        .glassSurface(cornerRadius: 22)
    }

    private var allLightsCard: some View {
        let state = controller.allLightsState
        let isLit = state == .on || state == .mixed
        let glow = state == .on ? 1.0 : (state == .mixed ? 0.45 : 0)
        let count = controller.lightSettingsItems.count
        return HStack(spacing: 14) {
            lightIcon(state)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("Todas las luces"))
                    .font(.headline)
                    .lineLimit(1)
                Text((count == 1 ? L10n.text("1 dispositivo") : L10n.format("%@ dispositivos", String(count))) + " · " + controller.allLightsStatusTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                actionButton(L10n.text("Alternar"), icon: "power", prominent: true, action: .toggleAllLights, shortcutActionID: "lights.toggle")
                actionButton(L10n.text("Encender"), icon: "sun.max.fill", action: .setAllLights(true))
                actionButton(L10n.text("Apagar"), icon: "moon.fill", action: .setAllLights(false))
            }
            .frame(width: 318)
            Button {
                controller.reloadConfiguration()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L10n.text("Recargar"))
            .help(L10n.text("Recargar"))
            .disabled(controller.isBusy)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 22, tint: isLit ? .orange : .cyan, glow: glow)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: state)
    }

    private func lightIcon(_ state: DevicePowerState) -> some View {
        let isLit = state == .on || state == .mixed
        let glow = state == .on ? 1.0 : (state == .mixed ? 0.45 : 0)
        return Image(systemName: "sun.max.fill")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(isLit ? Color.orange : .secondary)
            .frame(width: 42, height: 42)
            .background((isLit ? Color.orange : .blue).opacity(isLit ? 0.16 : 0.05), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.orange.opacity(glow * 0.16), lineWidth: 0.75))
            .shadow(color: .orange.opacity(glow * 0.15), radius: 10)
    }

    private func lightCard(_ group: LightGroup) -> some View {
        let state = controller.groupStates[group.id] ?? .unknown
        let isLit = state == .on || state == .mixed
        let glow = state == .on ? 1.0 : (state == .mixed ? 0.45 : 0)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                lightIcon(state)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title)
                        .font(.headline)
                        .lineLimit(1)
                        .help(group.title)
                    Text(group.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(controller.lightStatusTitle(for: group.id, deviceCount: group.lights.count))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(isLit ? Color.orange : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background((isLit ? Color.orange : .secondary).opacity(0.08), in: Capsule())
            }

            HStack(spacing: 8) {
                actionButton(L10n.text("Alternar"), icon: "power", prominent: true, action: .toggleGroup(group.id), shortcutActionID: group.shortcutActionID)
                actionButton(L10n.text("Encender"), icon: "sun.max.fill", action: .setGroup(group.id, true))
                actionButton(L10n.text("Apagar"), icon: "moon.fill", action: .setGroup(group.id, false))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 22, tint: isLit ? .orange : .cyan, glow: glow)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: state)
    }

    private var lockCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 12) {
                Image(systemName: controller.lockIsOpen ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.mint)
                    .frame(width: 42, height: 42)
                    .background(Color.mint.opacity(0.15), in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.mint.opacity(0.14), lineWidth: 0.75))
                    .shadow(color: .mint.opacity(controller.lockIsOpen ? 0.2 : 0.05), radius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.lockTitle).font(.headline).lineLimit(1).help(controller.lockTitle)
                    Text(L10n.format("Estado: %@", controller.lockStatusTitle)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(controller.lockConfigurationLoaded ? .green : .orange)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(L10n.text(controller.lockConfigurationLoaded ? "Configurada" : "Sin configurar"))
            }

            if !controller.lockConfigurationLoaded {
                Text(controller.lockConfigurationError ?? L10n.text("Configuración pendiente"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                actionButton(L10n.text("Abrir"), icon: "lock.open.fill", prominent: true, action: .doorUnlock, shortcutActionID: "door.unlock")
                actionButton(L10n.text("Esperar solicitud"), icon: "bell.badge.fill", action: .doorWaitAndUnlock, shortcutActionID: "door.wait")
                actionButton(L10n.text("Consultar"), icon: "exclamationmark.circle", action: .doorStatus)
            }
            .disabled(!controller.lockConfigurationLoaded)
        }
        .padding(18)
        .glassSurface(cornerRadius: 22, tint: .cyan, glow: controller.lockIsOpen ? 0.7 : 0.2)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: controller.lockIsOpen)
    }

    private func actionButton(
        _ title: String,
        icon: String,
        prominent: Bool = false,
        action: HomeController.Action,
        shortcutActionID: String? = nil
    ) -> some View {
        let isActive = controller.activeAction == action
        let isComplete = controller.completedAction == action
        let shortcut = shortcutActionID.flatMap { shortcutManager.binding(for: $0)?.displayName }
        return Button {
            controller.run(action)
        } label: {
            HStack(spacing: 6) {
                if isActive {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: isComplete ? "checkmark" : icon)
                }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .glassActionStyle(prominent: prominent)
        .disabled(controller.isBusy)
        .help(shortcut.map { title + " · " + L10n.format("Atajo: %@", $0) } ?? title)
        .accessibilityValue(isActive ? L10n.text("En curso") : (isComplete ? L10n.text("Completado") : ""))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isComplete)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("© \(String(Calendar.current.component(.year, from: .now))) Denis Gontero")
                .foregroundStyle(.secondary)
            Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.primary.opacity(0.04), in: Capsule())
            Spacer()
            Link(destination: URL(string: "https://github.com/DevnisG")!) {
                HStack(spacing: 5) {
                    Image("GitHubMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                    Text("GitHub")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(.secondary)
            .help(L10n.text("Ver perfil en GitHub"))
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LinearGradient(colors: [.clear, .cyan.opacity(0.15), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 0.5)
                .padding(.horizontal, 28)
        }
    }
}
