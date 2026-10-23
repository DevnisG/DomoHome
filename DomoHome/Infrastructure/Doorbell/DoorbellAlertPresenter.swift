import AppKit
import SwiftUI

@MainActor
final class DoorbellAlertModel: ObservableObject {
    @Published var snapshot = DoorbellSnapshot()
    var onOpen: (() -> Void)?
    var onIgnore: (() -> Void)?
    var maximumSeconds = 60.0
}

private final class DoorbellAlertPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum DoorbellPalette {
    static let open = Color(.sRGB, red: 0.18, green: 0.83, blue: 0.43, opacity: 1)
    static let ignore = Color(.sRGB, red: 1, green: 0.32, blue: 0.36, opacity: 1)
}

private struct DoorbellCountdownStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(DoorbellPalette.open)
                    .frame(width: geometry.size.width * min(1, max(0, configuration.fractionCompleted ?? 0)))
            }
        }
        .frame(height: 6)
    }
}

private struct DoorbellActionStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(color)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(color.opacity(configuration.isPressed ? 0.4 : 0.24), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.7)))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct DoorbellAlertView: View {
    @ObservedObject var model: DoorbellAlertModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image("AppBrandMark")
                    .resizable().scaledToFit().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("DomoHome").font(.headline)
                    Text(L10n.text("Cerradura · Timbre detectado"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "bell.badge").foregroundStyle(.secondary)
            }
            Text(L10n.text("Alguien está llamando a la puerta."))
            HStack {
                Text(L10n.text("Ventana de apertura")).foregroundStyle(.secondary)
                Spacer()
                Text(model.snapshot.phase == .ringing
                     ? L10n.text("Esperando solicitud…")
                     : L10n.format("%@ segundos", String(model.snapshot.remainingSeconds)))
                    .fontWeight(.semibold).monospacedDigit()
            }
            .font(.callout)
            ProgressView(value: Double(model.snapshot.remainingSeconds), total: model.maximumSeconds)
                .progressViewStyle(DoorbellCountdownStyle())
            HStack(spacing: 10) {
                Button { model.onIgnore?() } label: {
                    Label(L10n.text("Ignorar"), systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DoorbellActionStyle(color: DoorbellPalette.ignore))
                Button { model.onOpen?() } label: {
                    Label(L10n.text("Abrir"), systemImage: "lock.open.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DoorbellActionStyle(color: DoorbellPalette.open))
                .disabled(!model.snapshot.canUnlock)
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.1)))
        .padding(1)
    }
}

@MainActor
final class DoorbellAlertPresenter: DoorbellAlertPresenting {
    private let model = DoorbellAlertModel()
    private var panel: NSPanel?
    private var sessionID: UUID?
    var onOpen: ((UUID) -> Void)?
    var onIgnore: ((UUID) -> Void)?

    func present(_ snapshot: DoorbellSnapshot) -> Bool {
        guard let id = snapshot.sessionID else { return false }
        sessionID = id
        model.maximumSeconds = max(60, Double(snapshot.remainingSeconds))
        model.snapshot = snapshot
        model.onOpen = { [weak self] in
            guard let self, let id = self.sessionID else { return }
            self.dismiss()
            self.onOpen?(id)
        }
        model.onIgnore = { [weak self] in
            guard let self, let id = self.sessionID else { return }
            self.dismiss()
            self.onIgnore?(id)
        }
        if panel == nil {
            let panel = DoorbellAlertPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.contentView = NSHostingView(rootView: DoorbellAlertView(model: model)
                .environment(\.controlActiveState, .active))
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .popUpMenu
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.isExcludedFromWindowsMenu = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isMovableByWindowBackground = true
            self.panel = panel
        }
        panel?.setContentSize(NSSize(width: 442, height: 238))
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }), let panel {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        }
        showPanel()
        return panel?.isVisible == true
    }

    func update(_ snapshot: DoorbellSnapshot) {
        guard sessionID == snapshot.sessionID, [.ringing, .available].contains(snapshot.phase) else {
            dismiss()
            return
        }
        model.maximumSeconds = max(model.maximumSeconds, Double(snapshot.remainingSeconds))
        model.snapshot = snapshot
        showPanel()
    }

    private func showPanel() {
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if panel?.isMiniaturized == true { panel?.deminiaturize(nil) }
        panel?.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
        sessionID = nil
    }
}
