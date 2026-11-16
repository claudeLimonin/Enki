import AppKit
import Carbon.HIToolbox

/// Raccourcis clavier globaux (actifs depuis n'importe quelle app).
/// Mécanisme système « hot keys » : aucune autorisation d'accessibilité nécessaire.
final class Hotkeys {
    struct Shortcut {
        let keyCode: UInt32
        let label: String
        let title: String
        let action: () -> Void
    }

    /// ⌃⌥⌘ : combinaison peu utilisée par les autres apps.
    static let modifierLabel = "⌃⌥⌘"
    private let modifiers = UInt32(controlKey | optionKey | cmdKey)
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private(set) var shortcuts: [Shortcut] = []

    init(_ shortcuts: [Shortcut]) {
        self.shortcuts = shortcuts
    }

    var isRegistered: Bool { !refs.isEmpty }

    func register() {
        guard refs.isEmpty else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            guard let event, let user else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(user).takeUnretainedValue()
            let index = Int(id.id)
            if hotkeys.shortcuts.indices.contains(index) {
                DispatchQueue.main.async { hotkeys.shortcuts[index].action() }
            }
            return noErr
        }, 1, &spec, me, &handler)

        for (i, s) in shortcuts.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4547_4C5A), id: UInt32(i))  // « EGLZ »
            if RegisterEventHotKey(s.keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
    }

    func unregister() {
        for r in refs { UnregisterEventHotKey(r) }
        refs = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

/// Petite bulle d'information sous l'icône de la barre des menus, qui disparaît seule.
final class HUD {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, symbol: String, below anchor: NSView?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: HUDContent(text: text, symbol: symbol))
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(host.fittingSize)

        // Sous l'icône si possible, sinon en haut à droite de l'écran principal.
        var origin = CGPoint.zero
        if let anchor, let window = anchor.window {
            let r = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            origin = CGPoint(x: r.midX - host.fittingSize.width / 2, y: r.minY - host.fittingSize.height - 8)
        } else if let screen = NSScreen.main {
            origin = CGPoint(x: screen.visibleFrame.maxX - host.fittingSize.width - 16,
                             y: screen.visibleFrame.maxY - host.fittingSize.height - 8)
        }
        if let screen = NSScreen.main {
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - host.fittingSize.width - 8)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                panel?.animator().alphaValue = 0
            }, completionHandler: { panel?.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return p
    }
}

import SwiftUI

private struct HUDContent: View {
    let text: String
    let symbol: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
            Text(text).font(.system(size: 13, weight: .medium)).lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .padding(4)
    }
}
