import SwiftUI

enum DeviceEditorSelection: Equatable, Identifiable {
    case light(String?)
    case lock

    var id: String {
        switch self {
        case .light(let id): "light:" + (id ?? "new")
        case .lock: "lock"
        }
    }
}

struct DeviceSetupView: View {
    let selection: DeviceEditorSelection
    let onClose: () -> Void
    @EnvironmentObject private var controller: HomeController
    @State private var light: LightSetup
    @State private var lock: LockSetup
    @State private var confirmRemoval = false
    @State private var isEditingExisting = false

    init(selection: DeviceEditorSelection, document: ConfigurationDocument, onClose: @escaping () -> Void) {
        self.selection = selection
        self.onClose = onClose
        var light = LightSetup(switchDPID: document.switchDPID)
        var lock = LockSetup()
        var existing = false
        switch selection {
        case .light(let id):
            if let record = document.lights.first(where: { $0.id == id }) {
                light.originalID = record.id
                light.deviceID = record.deviceID
                light.ip = record.ip
                light.displayName = record.displayName
                light.group = record.group
                existing = true
            }
        case .lock:
            if let record = document.lock {
                lock.clientID = record.clientID
                lock.apiHost = record.apiHost
                lock.deviceID = record.deviceID
                lock.displayName = record.displayName
                lock.group = record.group
                existing = true
            }
        }
        _light = State(initialValue: light)
        _lock = State(initialValue: lock)
        _isEditingExisting = State(initialValue: existing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.text(isEditingExisting ? "Editar dispositivo" : "Configurar dispositivo"),
                  systemImage: selection == .lock ? "lock.fill" : "sun.max.fill")
                .font(.headline)
            switch selection {
            case .light: lightFields
            case .lock: lockFields
            }
            Text(L10n.text(isEditingExisting ? "Dejá la clave vacía para conservar la actual." : "Las credenciales se guardan en el llavero de macOS."))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 12) {
                if isEditingExisting {
                    Button(L10n.text("Quitar dispositivo"), role: .destructive) { confirmRemoval = true }
                        .controlSize(.small)
                }
                Spacer()
                Button(L10n.text("Cancelar")) { close() }
                Button(L10n.text("Guardar")) { save() }
                    .glassActionStyle(prominent: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 22, tint: .cyan)
        .disabled(controller.isBusy)
        .confirmationDialog(L10n.text("¿Quitar este dispositivo de DomoHome?"), isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button(L10n.text("Quitar dispositivo"), role: .destructive) { remove() }
            Button(L10n.text("Cancelar"), role: .cancel) {}
        } message: {
            Text(L10n.text("Se eliminarán su configuración local y su credencial guardada. El dispositivo físico no se modifica."))
        }
        .onDisappear {
            light.localKey = ""
            lock.clientSecret = ""
        }
    }

    private var lightFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                field("Nombre visible", text: $light.displayName)
                field("Grupo opcional", text: $light.group)
            }
            HStack(spacing: 16) {
                field("ID del dispositivo", text: $light.deviceID)
                field("Dirección IP", text: $light.ip)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("Clave local")).font(.caption.weight(.medium))
                    SecureField(L10n.text("Clave local"), text: $light.localKey)
                        .textFieldStyle(.roundedBorder)
                        .privacySensitive()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("DPID de encendido")).font(.caption.weight(.medium))
                    Stepper(value: $light.switchDPID, in: 1...255) {
                        Text(String(light.switchDPID)).monospacedDigit()
                    }
                }
                .frame(width: 170)
            }
            Text(L10n.text("Tuya LAN 3.3 · El DPID se aplica a todas las luces."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var lockFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                field("Nombre visible", text: $lock.displayName)
                field("Grupo opcional", text: $lock.group)
            }
            HStack(spacing: 16) {
                field("ID del dispositivo", text: $lock.deviceID)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("Región de Tuya")).font(.caption.weight(.medium))
                    Picker(L10n.text("Región de Tuya"), selection: $lock.apiHost) {
                        ForEach(TuyaRegion.allCases) { region in Text(region.title).tag(region.rawValue) }
                    }
                    .labelsHidden()
                }
                .frame(width: 220)
            }
            field("Client ID de Tuya", text: $lock.clientID)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("Secreto de Tuya")).font(.caption.weight(.medium))
                SecureField(L10n.text("Secreto de Tuya"), text: $lock.clientSecret)
                    .textFieldStyle(.roundedBorder)
                    .privacySensitive()
            }
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text(title)).font(.caption.weight(.medium))
            TextField(L10n.text(title), text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func save() {
        let saved: Bool
        switch selection {
        case .light: saved = controller.saveLight(light)
        case .lock: saved = controller.saveLock(lock)
        }
        if saved { close() }
    }

    private func remove() {
        let removed: Bool
        switch selection {
        case .light(let id): removed = id.map { controller.removeLight(id: $0) } ?? false
        case .lock: removed = controller.removeLock()
        }
        if removed { close() }
    }

    private func close() {
        light.localKey = ""
        lock.clientSecret = ""
        onClose()
    }
}
