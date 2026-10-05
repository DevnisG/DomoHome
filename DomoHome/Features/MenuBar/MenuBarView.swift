import AppKit
import SwiftUI

struct MenuBarView: NSViewRepresentable {
    let appDelegate: AppDelegate

    func makeCoordinator() -> Coordinator {
        Coordinator(appDelegate: appDelegate)
    }

    func makeNSView(context: Context) -> NSButton {
        let image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))!
        image.isTemplate = true
        let button = NSButton(image: image, target: context.coordinator, action: #selector(Coordinator.showMenu(_:)))
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.focusRingType = .none
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.toolTip = L10n.text("Acciones rápidas")
        button.setAccessibilityLabel(L10n.text("Acciones rápidas"))
    }

    @MainActor
    final class Coordinator: NSObject {
        private let appDelegate: AppDelegate

        init(appDelegate: AppDelegate) {
            self.appDelegate = appDelegate
        }

        @objc func showMenu(_ sender: NSButton) {
            appDelegate.makeActionMenu().popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.minY - 4),
                in: sender
            )
        }
    }
}

@MainActor
final class MenuItemRowView: NSView {
    private let titleLabel: NSTextField
    private let symbolView = NSImageView()
    private var pointerTrackingArea: NSTrackingArea?
    private var isHighlighted = false

    init(title: String, symbol: String) {
        titleLabel = NSTextField(labelWithString: title)
        let font = NSFont.menuFont(ofSize: 0)
        let titleWidth = (title as NSString).size(withAttributes: [.font: font]).width
        super.init(frame: NSRect(x: 0, y: 0, width: max(196, ceil(titleWidth) + 58), height: 26))

        autoresizingMask = [.width]
        titleLabel.font = font
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityElement(false)

        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        symbolView.image?.isTemplate = true
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.setAccessibilityElement(false)

        addSubview(titleLabel)
        addSubview(symbolView)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 14, y: (bounds.height - 18) / 2, width: max(0, bounds.width - 58), height: 18)
        symbolView.frame = NSRect(x: bounds.maxX - 30, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isHighlighted && enclosingMenuItem?.isEnabled == true {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setHighlighted(false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard let item = enclosingMenuItem, item.isEnabled else { return }
        for entry in item.menu?.items ?? [] {
            (entry.view as? MenuItemRowView)?.setHighlighted(entry === item)
        }
    }

    override func mouseExited(with event: NSEvent) {
        setHighlighted(false)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        setHighlighted(bounds.contains(convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        performAction()
    }

    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) {
            performAction()
        } else {
            super.keyDown(with: event)
        }
    }

    override func isAccessibilityEnabled() -> Bool {
        enclosingMenuItem?.isEnabled ?? true
    }

    override func accessibilityPerformPress() -> Bool {
        performAction()
    }

    func setHighlighted(_ highlighted: Bool) {
        isHighlighted = highlighted
        updateAppearance()
        needsDisplay = true
    }

    private func updateAppearance() {
        let color: NSColor
        if enclosingMenuItem?.isEnabled == false {
            color = .disabledControlTextColor
        } else if isHighlighted {
            color = .selectedMenuItemTextColor
        } else {
            color = .labelColor
        }
        titleLabel.textColor = color
        symbolView.contentTintColor = color
    }

    @discardableResult
    fileprivate func performAction() -> Bool {
        guard let item = enclosingMenuItem, item.isEnabled, let menu = item.menu else { return false }
        let index = menu.index(of: item)
        guard index >= 0 else { return false }
        menu.cancelTracking()
        menu.performActionForItem(at: index)
        return true
    }
}

@MainActor
final class ActionMenuItem: NSMenuItem {
    override func accessibilityPerformPress() -> Bool {
        guard let row = view as? MenuItemRowView else { return super.accessibilityPerformPress() }
        return row.performAction()
    }
}
