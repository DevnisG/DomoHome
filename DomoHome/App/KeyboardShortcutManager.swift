import AppKit
import Carbon
import Combine

struct ShortcutBinding: Codable, Equatable {
    let keyCode: UInt32
    let keyLabel: String
    let command: Bool
    let option: Bool
    let control: Bool
    let shift: Bool

    var carbonModifiers: UInt32 {
        (command ? UInt32(cmdKey) : 0)
            | (option ? UInt32(optionKey) : 0)
            | (control ? UInt32(controlKey) : 0)
            | (shift ? UInt32(shiftKey) : 0)
    }

    var displayKeys: [String] {
        [control ? "⌃" : "", option ? "⌥" : "", shift ? "⇧" : "", command ? "⌘" : ""]
            .filter { !$0.isEmpty } + [keyLabel]
    }

    var displayName: String { displayKeys.joined(separator: " ") }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.carbonModifiers == rhs.carbonModifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        let specialKeys: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "␣", 51: "⌫", 76: "⌤", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
        ]
        keyLabel = specialKeys[event.keyCode] ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? "?"
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        command = modifiers.contains(.command)
        option = modifiers.contains(.option)
        control = modifiers.contains(.control)
        shift = modifiers.contains(.shift)
    }
}

enum ShortcutSound: String, CaseIterable, Identifiable {
    case tink = "Tink"
    case pop = "Pop"
    case glass = "Glass"
    case ping = "Ping"
    case purr = "Purr"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tink: L10n.text("Sutil")
        case .pop: L10n.text("Burbuja")
        case .glass: L10n.text("Cristal")
        case .ping: L10n.text("Campana")
        case .purr: L10n.text("Suave")
        }
    }
}

@MainActor
final class GlobalShortcutManager: ObservableObject {
    @Published private(set) var bindings: [String: ShortcutBinding]
    @Published private(set) var feedback: String?
    @Published private(set) var registrationErrors: [String: String] = [:]
    @Published private(set) var recordingActionID: String?
    @Published var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: soundPreferenceKey) }
    }
    @Published var selectedSound: ShortcutSound {
        didSet { defaults.set(selectedSound.rawValue, forKey: selectedSoundPreferenceKey) }
    }

    private let preferenceKey = "domoHomeKeyboardShortcuts"
    private let soundPreferenceKey = "domoHomeShortcutSoundEnabled"
    private let selectedSoundPreferenceKey = "domoHomeShortcutSound"
    private let defaults: UserDefaults
    private weak var controller: HomeController?
    private var eventHandler: EventHandlerRef?
    private var registeredHotKeys: [EventHotKeyRef] = []
    private var actionByHotKeyID: [UInt32: String] = [:]
    private var nextHotKeyID: UInt32 = 0
    private var validActionIDs: Set<String> = []
    private var configurationSubscription: AnyCancellable?
    private var keyboardMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var playingSound: NSSound?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        soundEnabled = defaults.object(forKey: soundPreferenceKey) as? Bool ?? true
        selectedSound = ShortcutSound(rawValue: defaults.string(forKey: selectedSoundPreferenceKey) ?? "") ?? .tink
        if let data = defaults.data(forKey: preferenceKey),
           let decoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            bindings = decoded
        } else {
            bindings = [:]
        }
    }

    deinit {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        registeredHotKeys.forEach { UnregisterEventHotKey($0) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func configure(controller: HomeController) {
        self.controller = controller
        installEventHandlerIfNeeded()
        if keyboardMonitor == nil {
            keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if self.recordingActionID != nil {
                    self.capture(event)
                    return nil
                }
                let binding = ShortcutBinding(event: event)
                guard let actionID = self.bindings.first(where: { $0.value == binding })?.key,
                      self.actionByHotKeyID.values.contains(actionID) else { return event }
                if !event.isARepeat { self.executeShortcut(actionID) }
                return nil
            }
        }
        reconcileBindings(groups: controller.lightGroups, hasLock: controller.lockConfigurationLoaded)
        configurationSubscription = controller.$lightGroups
            .combineLatest(controller.$lockConfigurationLoaded)
            .receive(on: RunLoop.main)
            .sink { [weak self] groups, hasLock in
                self?.reconcileBindings(groups: groups, hasLock: hasLock)
            }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.cancelRecording() }
            }
        }
    }

    func binding(for actionID: String) -> ShortcutBinding? { bindings[actionID] }

    func assign(_ binding: ShortcutBinding, to actionID: String) {
        guard validActionIDs.contains(actionID) else { cancelRecording(); return }
        guard binding.carbonModifiers != 0 else { reportInvalidCapture(); return }
        guard !bindings.contains(where: { $0.key != actionID && $0.value == binding }) else {
            feedback = L10n.text("Ese atajo ya está asignado.")
            return
        }
        let previous = bindings[actionID]
        stopCapture()
        bindings[actionID] = binding
        feedback = nil
        registerBindings()
        if let error = registrationErrors[actionID] {
            bindings[actionID] = previous
            registerBindings()
            registrationErrors[actionID] = error
            feedback = error
        }
        persistBindings()
    }

    func removeBinding(for actionID: String) {
        stopCapture()
        bindings.removeValue(forKey: actionID)
        feedback = nil
        persistBindings()
        registerBindings()
    }

    func beginRecording(actionID: String) {
        guard validActionIDs.contains(actionID) else { return }
        stopCapture()
        unregisterBindings()
        feedback = nil
        recordingActionID = actionID
    }

    func capture(_ event: NSEvent) {
        guard let actionID = recordingActionID, !event.isARepeat else { return }
        if event.keyCode == 53 { cancelRecording(); return }
        assign(ShortcutBinding(event: event), to: actionID)
    }

    func cancelRecording() {
        guard recordingActionID != nil else { return }
        stopCapture()
        feedback = nil
        registerBindings()
    }

    private func stopCapture() {
        recordingActionID = nil
    }

    private func reportInvalidCapture() {
        feedback = L10n.text("Incluí Control, Option, Shift o Command en el atajo.")
    }

    private func reconcileBindings(groups: [LightGroup], hasLock: Bool) {
        var validIDs = Set(groups.map(\.shortcutActionID))
        if !groups.isEmpty { validIDs.insert("lights.toggle") }
        if hasLock { validIDs.formUnion(["door.unlock", "door.wait"]) }
        var updated = bindings
        let previousOn = updated.removeValue(forKey: "lights.on")
        let previousOff = updated.removeValue(forKey: "lights.off")
        if updated["lights.toggle"] == nil, !groups.isEmpty {
            updated["lights.toggle"] = previousOn ?? previousOff
        }
        for group in groups {
            let legacyID = "light:\(group.id)"
            if let binding = updated.removeValue(forKey: legacyID), updated[group.shortcutActionID] == nil {
                updated[group.shortcutActionID] = binding
            }
        }
        updated = updated.filter { validIDs.contains($0.key) }
        let changed = validActionIDs != validIDs || updated != bindings
        validActionIDs = validIDs
        if updated != bindings {
            bindings = updated
            persistBindings()
        }
        if let recordingActionID, !validIDs.contains(recordingActionID) { stopCapture() }
        if changed || actionByHotKeyID.isEmpty { registerBindings() }
    }

    private func persistBindings() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: preferenceKey)
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerProcPtr = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            guard hotKeyID.signature == OSType(0x44484F4D) else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in manager.perform(identifier: hotKeyID.id) }
            return noErr
        }
        let status = InstallEventHandler(GetEventDispatcherTarget(), callback, 1, &eventType,
                                         Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if status != noErr { feedback = L10n.text("No se pudo activar el servicio de atajos.") }
    }

    private func unregisterBindings() {
        registeredHotKeys.forEach { UnregisterEventHotKey($0) }
        registeredHotKeys = []
        actionByHotKeyID = [:]
    }

    private func registerBindings() {
        unregisterBindings()
        registrationErrors = [:]
        guard eventHandler != nil, recordingActionID == nil else { return }
        for actionID in bindings.keys.sorted() where validActionIDs.contains(actionID) {
            guard let binding = bindings[actionID] else { continue }
            nextHotKeyID &+= 1
            var reference: EventHotKeyRef?
            let identifier = nextHotKeyID
            let status = RegisterEventHotKey(binding.keyCode, binding.carbonModifiers,
                EventHotKeyID(signature: OSType(0x44484F4D), id: identifier), GetEventDispatcherTarget(), UInt32(kEventHotKeyExclusive), &reference)
            if status == noErr, let reference {
                registeredHotKeys.append(reference)
                actionByHotKeyID[identifier] = actionID
            } else {
                registrationErrors[actionID] = L10n.format("macOS no permitió registrar el atajo %@.", binding.displayName)
            }
        }
    }

    private func perform(identifier: UInt32) {
        guard let actionID = actionByHotKeyID[identifier] else { return }
        executeShortcut(actionID)
    }

    func executeShortcut(_ actionID: String) {
        guard recordingActionID == nil, validActionIDs.contains(actionID), let controller, !controller.isLaunching else { return }
        let action: HomeController.Action
        if let group = controller.lightGroups.first(where: { $0.shortcutActionID == actionID }) {
            action = .toggleGroup(group.id)
        } else if actionID == "lights.toggle" {
            action = .toggleAllLights
        } else if actionID == "door.unlock" {
            action = .doorUnlock
        } else if actionID == "door.wait" {
            action = .doorWaitAndUnlock
        } else {
            return
        }
        if controller.run(action) { playShortcutSound() }
    }

    func previewShortcutSound() { playShortcutSound() }

    private func playShortcutSound() {
        guard soundEnabled, let sound = NSSound(named: NSSound.Name(selectedSound.rawValue)) else { return }
        playingSound?.stop()
        playingSound = sound
        sound.volume = 0.18
        sound.play()
    }
}
