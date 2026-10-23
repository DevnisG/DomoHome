import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: HomeController
    @EnvironmentObject private var shortcutManager: GlobalShortcutManager
    @AppStorage(AppLanguage.preferenceKey) private var languageCode = AppLanguage.spanish.rawValue
    @StateObject private var loginItemManager = LoginItemManager()

    @State private var lightNames: [String: String] = [:]
    @State private var lightGroups: [String: String] = [:]
    @State private var lockDisplayName = ""
    @State private var lockGroup = ""
    @State private var editor: DeviceEditorSelection?

    private var hasUnsavedLabels: Bool {
        controller.configurationDocument.lights.contains {
            lightNames[$0.id, default: ""] != $0.displayName || lightGroups[$0.id, default: ""] != $0.group
        } || lockDisplayName != (controller.configurationDocument.lock?.displayName ?? "")
            || lockGroup != (controller.configurationDocument.lock?.group ?? "")
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(L10n.text("Ajustes")).font(.title3.bold())
                Spacer()
                Button {
                    controller.reloadConfiguration()
                } label: {
                    Label(L10n.text("Recargar"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(controller.isBusy || hasUnsavedLabels || editor != nil)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        settingsSection("Ajustes generales", icon: "gearshape") {
                            generalCard
                        }
                        settingsSection("Dispositivos", icon: "square.grid.2x2") {
                            if let editor {
                                DeviceSetupView(selection: editor, document: controller.configurationDocument) {
                                    self.editor = nil
                                }
                                .id(editor.id)
                            } else {
                                deviceCard
                                if controller.configurationDocument.lock != nil { lockCard }
                            }
                        }
                        .id("devices")
                        settingsSection("Atajos de teclado", icon: "keyboard") {
                            shortcutCard
                        }
                        settingsSection("Estado y privacidad", icon: "lock.shield") {
                            statusCard
                            sourceCard
                        }
                        settingsSection("Acerca de DomoHome", icon: "info.circle") {
                            aboutCard
                        }
                    }
                    .padding(.bottom, 20)
                }
                .onChange(of: editor) { _, selection in
                    shortcutManager.cancelRecording()
                    if selection != nil { proxy.scrollTo("devices", anchor: .top) }
                }
                .onAppear {
                    if !controller.hasConfiguredDevices { proxy.scrollTo("devices", anchor: .top) }
                }
            }
            if hasUnsavedLabels { labelActions.padding(.bottom, 8) }
        }
        .padding(.horizontal, 28)
        .onAppear { resetLabels() }
        .onChange(of: controller.configurationDocument) { _, _ in resetLabels() }
        .onDisappear { shortcutManager.cancelRecording() }
    }

    private func settingsSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L10n.text(title), systemImage: icon)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var doorbellPreferences: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L10n.text("Notificaciones del timbre"), isOn: Binding(
                get: { controller.doorbell.settings.notificationsEnabled },
                set: { value in
                    var settings = controller.doorbell.settings
                    settings.notificationsEnabled = value
                    controller.updateDoorbellSettings(settings)
                }
            ))
            if controller.doorbell.notificationPermission != "Permitidas" {
                Button(L10n.text("Permitir notificaciones")) { controller.doorbell.notifications.requestPermission() }
                    .controlSize(.small)
            }
        }
    }

    private var shortcutCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Funcionan aunque DomoHome esté en segundo plano."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if shortcutManager.recordingActionID != nil {
                    Text(L10n.text("Escape para cancelar."))
                        .font(.caption)
                        .foregroundStyle(.cyan)
                }
            }

            if !controller.hasConfiguredDevices {
                Label(L10n.text("Configurá un dispositivo para asignarle un atajo."), systemImage: "keyboard")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }

            if !controller.lightGroups.isEmpty {
                shortcutRow(title: L10n.text("Alternar todas"), actionID: "lights.toggle", icon: "power")
                Divider()
            }

            ForEach(controller.lightGroups) { group in
                shortcutRow(
                    title: L10n.format("Alternar %@", group.title),
                    actionID: group.shortcutActionID,
                    icon: "sun.max.fill"
                )
                Divider()
            }

            if controller.lockConfigurationLoaded {
                shortcutRow(title: L10n.text("Abrir cerradura"), actionID: "door.unlock", icon: "lock.open.fill")
                Divider()
                shortcutRow(title: L10n.text("Abrir cerradura (atajo alternativo)"), actionID: "door.wait", icon: "bell.badge.fill")
            }

            if shortcutManager.recordingActionID == nil, let feedback = shortcutManager.feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 22)
    }

    private func shortcutRow(title: String, actionID: String, icon: String) -> some View {
        let binding = shortcutManager.binding(for: actionID)
        let isRecording = shortcutManager.recordingActionID == actionID
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .foregroundStyle(.cyan)
                    .frame(width: 30, height: 30)
                    .background(.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Button {
                    shortcutManager.beginRecording(actionID: actionID)
                } label: {
                    shortcutLabel(binding: binding, isRecording: isRecording)
                        .frame(width: 190, height: 32)
                        .padding(5)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(isRecording ? .cyan.opacity(0.6) : .primary.opacity(0.09), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help(L10n.text(isRecording ? "Escape para cancelar." : "Hacé clic para grabar un atajo."))
                .accessibilityLabel(title + ": " + (isRecording ? L10n.text("Presioná una combinación…") : binding?.displayName ?? L10n.text("Sin asignar")))
                Group {
                    if binding != nil {
                        Button {
                            shortcutManager.removeBinding(for: actionID)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("Quitar atajo"))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 24, height: 24)
            }
            if let error = shortcutManager.registrationErrors[actionID] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if isRecording, let feedback = shortcutManager.feedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func shortcutLabel(binding: ShortcutBinding?, isRecording: Bool) -> some View {
        if isRecording {
            Text(L10n.text("Presioná una combinación…"))
                .font(.caption)
                .foregroundStyle(.cyan)
        } else if let binding {
            HStack(spacing: 6) {
                ForEach(Array(binding.displayKeys.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.system(size: 14, weight: .medium))
                        .frame(minWidth: 23, minHeight: 26)
                        .padding(.horizontal, 3)
                        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                }
            }
        } else {
            Label(L10n.text("Sin asignar"), systemImage: "plus")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var generalCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            languageRow
            Divider()
            loginItemRow
            if let message = loginItemManager.errorMessage {
                Text(L10n.text(message))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if loginItemManager.requiresApproval {
                Button(L10n.text("Permitir en Ajustes del Sistema")) { loginItemManager.openSettings() }
                    .font(.caption)
                    .buttonStyle(.link)
            }
            if controller.lockConfigurationLoaded {
                Divider()
                doorbellListeningRow
            }
            Divider()
            soundRow
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 22)
    }

    private var doorbellListeningRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Escuchar timbre"))
                    .font(.subheadline.weight(.medium))
                Text(L10n.text("Al desactivar, se detiene la escucha y se cierran las alertas pendientes."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(L10n.text("Escuchar timbre"), isOn: Binding(
                get: { controller.doorbell.settings.enabled },
                set: { enabled in
                    var settings = controller.doorbell.settings
                    settings.enabled = enabled
                    controller.updateDoorbellSettings(settings)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var loginItemRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Iniciar con la Mac"))
                    .font(.subheadline.weight(.medium))
                Text(L10n.text("Abrir DomoHome al iniciar sesión en la Mac."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(L10n.text("Iniciar con la Mac"), isOn: Binding(
                get: { loginItemManager.isEnabled },
                set: { enabled in Task { await loginItemManager.setEnabled(enabled) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(loginItemManager.isUpdating)
        }
    }

    private var soundRow: some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Sonido al ejecutar atajos"))
                        .font(.subheadline.weight(.medium))
                    Text(L10n.text("Un sonido breve al activar un atajo."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker(L10n.text("Sonido"), selection: $shortcutManager.selectedSound) {
                    ForEach(ShortcutSound.allCases) { sound in
                        Text(sound.title).tag(sound)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                .id(languageCode)
                .disabled(!shortcutManager.soundEnabled)
                Button {
                    shortcutManager.previewShortcutSound()
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L10n.text("Probar sonido"))
                .accessibilityLabel(L10n.text("Probar sonido"))
                .disabled(!shortcutManager.soundEnabled)
                Toggle(L10n.text("Sonido al ejecutar atajos"), isOn: $shortcutManager.soundEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

    }

    private var languageRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Idioma"))
                    .font(.headline)
                Text(L10n.text("Elegí el idioma de la interfaz."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker(L10n.text("Idioma"), selection: $languageCode) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }
            .labelsHidden()
            .frame(width: 150)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Estado de la configuración"))
                .font(.headline)
            statusRow(L10n.text("Luces"), loaded: controller.lightsConfigurationLoaded, error: controller.lightsConfigurationError)
            Divider()
            statusRow(L10n.text("Cerradura"), loaded: controller.lockConfigurationLoaded, error: controller.lockConfigurationError)
        }
        .padding(18)
        .glassSurface(cornerRadius: 22)
    }

    private func statusRow(_ title: String, loaded: Bool, error: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: loaded ? "checkmark.circle.fill" : (error == nil ? "minus.circle" : "exclamationmark.circle.fill"))
                .foregroundStyle(loaded ? .green : (error == nil ? .secondary : .orange))
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(loaded ? L10n.text("Lista") : (error ?? L10n.text("Sin configurar")))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 410, alignment: .trailing)
        }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Luces")).font(.headline)
                    Text(L10n.text("Los dispositivos con el mismo grupo aparecen juntos en Inicio."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("Agregar luz"), systemImage: "plus") { editor = .light(nil) }
                    .controlSize(.small)
                    .disabled(hasUnsavedLabels)
            }
            if !controller.configurationDocument.lights.isEmpty {
                HStack(spacing: 12) {
                    Text(L10n.text("Nombre visible")).frame(maxWidth: .infinity, alignment: .leading)
                    Text(L10n.text("Grupo opcional")).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 110).padding(.trailing, 38)
            }
            ForEach(Array(controller.configurationDocument.lights.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                lightRow(item, index: index)
            }
            if controller.configurationDocument.lights.isEmpty {
                Text(L10n.text("Todavía no hay luces disponibles"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if controller.configurationDocument.lock == nil {
                Divider()
                Button(L10n.text("Configurar cerradura"), systemImage: "lock.fill") { editor = .lock }
                    .controlSize(.small)
                    .disabled(hasUnsavedLabels)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 22)
        .disabled(controller.isBusy || editor != nil)
    }

    private func lightRow(_ item: StoredLight, index: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sun.max.fill")
                .foregroundStyle(.orange)
                .frame(width: 32, height: 32)
                .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            Text(L10n.format("Luz %@", String(index + 1)))
                .font(.subheadline.weight(.medium))
                .frame(width: 54, alignment: .leading)
            TextField(L10n.text("Nombre visible"), text: Binding(
                get: { lightNames[item.id, default: ""] }, set: { lightNames[item.id] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            TextField(L10n.text("Grupo opcional"), text: Binding(
                get: { lightGroups[item.id, default: ""] }, set: { lightGroups[item.id] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            Button { editor = .light(item.id) } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(L10n.text("Editar dispositivo"))
            .accessibilityLabel(L10n.text("Editar dispositivo") + ": " + item.displayName)
            .disabled(hasUnsavedLabels)
        }
    }

    private var lockCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 32, height: 1)
                Text(L10n.text("Nombre visible")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.text("Grupo opcional")).frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 26, height: 1)
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.mint)
                    .frame(width: 32, height: 32)
                    .background(Color.mint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                TextField(L10n.text("Cerradura"), text: $lockDisplayName)
                    .textFieldStyle(.roundedBorder)
                TextField(L10n.text("Grupo opcional"), text: $lockGroup)
                    .textFieldStyle(.roundedBorder)
                Button { editor = .lock } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help(L10n.text("Editar dispositivo"))
                .accessibilityLabel(L10n.text("Editar dispositivo") + ": " + L10n.text("Cerradura"))
                .disabled(hasUnsavedLabels)
            }
            DisclosureGroup(L10n.text("Timbre Tuya")) {
                doorbellPreferences.padding(.top, 8)
            }
            .font(.callout)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 22)
        .disabled(controller.isBusy || editor != nil)
    }

    private var labelActions: some View {
        HStack {
            Label(L10n.text("Cambios sin guardar"), systemImage: "pencil.circle")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(L10n.text("Cancelar")) { resetLabels() }
            Button(L10n.text("Guardar cambios")) {
                let updates = controller.configurationDocument.lights.map {
                    DeviceLabelUpdate(id: $0.id, displayName: lightNames[$0.id, default: ""], group: lightGroups[$0.id, default: ""])
                }
                if controller.saveDeviceLabels(updates, lockName: lockDisplayName, lockGroup: lockGroup) { resetLabels() }
            }
            .glassActionStyle(prominent: true)
        }
        .disabled(controller.isBusy || editor != nil)
    }

    private func resetLabels() {
        lightNames = Dictionary(uniqueKeysWithValues: controller.configurationDocument.lights.map { ($0.id, $0.displayName) })
        lightGroups = Dictionary(uniqueKeysWithValues: controller.configurationDocument.lights.map { ($0.id, $0.group) })
        lockDisplayName = controller.configurationDocument.lock?.displayName ?? ""
        lockGroup = controller.configurationDocument.lock?.group ?? ""
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.text("Datos locales"), systemImage: "lock.shield")
                .font(.headline)
            Text(L10n.text("Las claves se guardan en el llavero de macOS. Los dispositivos y grupos se guardan localmente, separados de las credenciales."))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(L10n.text("Mostrar en Finder"), systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ConfigurationStore.url.deletingLastPathComponent()])
                }
                if controller.configurationDocument.credentialReferences.isEmpty {
                    Button(L10n.text("Importar .env"), systemImage: "square.and.arrow.down") { importEnvironment() }
                }
            }
            .controlSize(.small)
            .disabled(controller.isBusy || hasUnsavedLabels || editor != nil)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 22)
    }

    private var appVersion: String {
        "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")
    }

    private var releaseDate: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "DomoHomeReleaseDate") as? String, !value.isEmpty else {
            return L10n.text("Pendiente de publicación")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { return L10n.text("Pendiente de publicación") }
        formatter.locale = Locale(identifier: languageCode)
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image("AppBrandMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                Text("DomoHome")
                    .font(.title3.bold())
                Spacer()
                Text(appVersion)
                    .font(.subheadline.monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.cyan.opacity(0.1), in: Capsule())
                    .accessibilityLabel(L10n.text("Versión") + ": " + appVersion)
            }
            Divider()
            aboutRow("Desarrollador", value: "Denis Gontero")
            aboutRow("Publicación", value: releaseDate)
            aboutRow("Licencia", value: "MIT")
            Divider()
            HStack {
                Link(destination: URL(string: "https://github.com/DevnisG")!) {
                    HStack(spacing: 8) {
                        Image("GitHubMark")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                        Text("DevnisG")
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                    }
                }
                .help(L10n.text("Ver perfil en GitHub"))
                .accessibilityLabel(L10n.text("Ver perfil en GitHub") + ": DevnisG")
                Spacer()
                Text("© 2026 Denis Gontero")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 22)
    }

    private func aboutRow(_ title: String, value: String) -> some View {
        HStack {
            Text(L10n.text(title))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private func importEnvironment() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = L10n.text("Seleccioná tu archivo .env privado. El archivo original se conserva.")
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            _ = controller.importConfiguration(at: url)
        }
    }
}
