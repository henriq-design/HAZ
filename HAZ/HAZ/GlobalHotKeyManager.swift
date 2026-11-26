import Carbon.HIToolbox

/// Registers system-wide hotkeys without requiring Accessibility permission.
/// Tool shortcuts are registered system-wide: Control + Option + F for
/// Magnifier and Control + Option + A for Area. Escape is only registered
/// while a tool is active, so it never hijacks normal use.
final class GlobalHotKeyManager {
    enum EventID: UInt32 {
        case magnifier = 1
        case escape = 2
        case zoom1 = 3
        case zoom2 = 4
        case zoom3 = 5
        case area = 6
    }

    var onMagnifierPressed: (() -> Void)?
    var onMagnifierReleased: (() -> Void)?
    var onEscapePressed: (() -> Void)?
    var onZoomLevelSelected: ((Int) -> Void)?
    var onAreaPressed: (() -> Void)?

    private let signature: OSType = 0x4D464C54 // "MFLT"
    private var eventHandler: EventHandlerRef?
    private var magnifierHotKey: EventHotKeyRef?
    private var escapeHotKey: EventHotKeyRef?
    private var zoom1HotKey: EventHotKeyRef?
    private var zoom2HotKey: EventHotKeyRef?
    private var zoom3HotKey: EventHotKeyRef?
    private var areaHotKey: EventHotKeyRef?

    init() {
        installEventHandler()
    }

    isolated deinit {
        unregisterEscape()
        unregisterMagnifier()
        unregisterArea()
        unregisterZoomLevels()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    @discardableResult
    func registerMagnifier() -> Bool {
        unregisterMagnifier()

        let hotKeyID = EventHotKeyID(signature: signature, id: EventID.magnifier.rawValue)
        let modifiers = UInt32(controlKey | optionKey)

        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_F),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &magnifierHotKey
        )

        if status != noErr {
            print("[HAZ] ERROR registering ⌃⌥F: \(status)")
            magnifierHotKey = nil
            return false
        }

        print("[HAZ] global shortcut ready: ⌃⌥F")
        return true
    }

    @discardableResult
    func registerArea() -> Bool {
        unregisterArea()

        let hotKeyID = EventHotKeyID(signature: signature, id: EventID.area.rawValue)
        let modifiers = UInt32(controlKey | optionKey)

        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &areaHotKey
        )

        if status != noErr {
            print("[HAZ] ERROR registering ⌃⌥A: \(status)")
            areaHotKey = nil
            return false
        }

        print("[HAZ] area shortcut ready: ⌃⌥A")
        return true
    }

    func registerZoomLevels() {
        unregisterZoomLevels()

        let modifiers = UInt32(controlKey | optionKey)
        zoom1HotKey = registerHotKey(keyCode: UInt32(kVK_ANSI_1), modifiers: modifiers, id: .zoom1)
        zoom2HotKey = registerHotKey(keyCode: UInt32(kVK_ANSI_2), modifiers: modifiers, id: .zoom2)
        zoom3HotKey = registerHotKey(keyCode: UInt32(kVK_ANSI_3), modifiers: modifiers, id: .zoom3)

        if zoom1HotKey != nil, zoom2HotKey != nil, zoom3HotKey != nil {
            print("[HAZ] zoom shortcuts ready: ⌃⌥1 / ⌃⌥2 / ⌃⌥3")
        }
    }

    @discardableResult
    func registerEscape() -> Bool {
        guard escapeHotKey == nil else { return true }

        let hotKeyID = EventHotKeyID(signature: signature, id: EventID.escape.rawValue)
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &escapeHotKey
        )

        if status != noErr {
            print("[HAZ] WARNING: Escape could not be registered: \(status)")
            escapeHotKey = nil
            return false
        }

        return true
    }

    func unregisterEscape() {
        if let escapeHotKey {
            UnregisterEventHotKey(escapeHotKey)
            self.escapeHotKey = nil
        }
    }

    private func unregisterMagnifier() {
        if let magnifierHotKey {
            UnregisterEventHotKey(magnifierHotKey)
            self.magnifierHotKey = nil
        }
    }

    private func unregisterArea() {
        if let areaHotKey {
            UnregisterEventHotKey(areaHotKey)
            self.areaHotKey = nil
        }
    }

    private func unregisterZoomLevels() {
        if let zoom1HotKey { UnregisterEventHotKey(zoom1HotKey) }
        if let zoom2HotKey { UnregisterEventHotKey(zoom2HotKey) }
        if let zoom3HotKey { UnregisterEventHotKey(zoom3HotKey) }
        zoom1HotKey = nil
        zoom2HotKey = nil
        zoom3HotKey = nil
    }

    private func registerHotKey(
        keyCode: UInt32,
        modifiers: UInt32,
        id: EventID
    ) -> EventHotKeyRef? {
        var hotKey: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id.rawValue)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )

        if status != noErr {
            print("[HAZ] WARNING registering zoom hotkey \(id.rawValue): \(status)")
            return nil
        }
        return hotKey
    }

    private func installEventHandler() {
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }

            let manager = Unmanaged<GlobalHotKeyManager>
                .fromOpaque(userData)
                .takeUnretainedValue()

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr else {
                return noErr
            }

            let eventKind = GetEventKind(event)
            // Carbon entrega estos eventos en el bucle principal de AppKit.
            MainActor.assumeIsolated {
                guard hotKeyID.signature == manager.signature else { return }
                manager.handle(id: hotKeyID.id, eventKind: eventKind)
            }
            return noErr
        }

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        if status != noErr {
            print("[HAZ] ERROR installing hotkey event handler: \(status)")
        }
    }

    private func handle(id: UInt32, eventKind: UInt32) {
        guard let eventID = EventID(rawValue: id) else { return }

        switch (eventID, eventKind) {
        case (.magnifier, UInt32(kEventHotKeyPressed)):
            onMagnifierPressed?()
        case (.magnifier, UInt32(kEventHotKeyReleased)):
            onMagnifierReleased?()
        case (.escape, UInt32(kEventHotKeyPressed)):
            onEscapePressed?()
        case (.zoom1, UInt32(kEventHotKeyPressed)):
            onZoomLevelSelected?(1)
        case (.zoom2, UInt32(kEventHotKeyPressed)):
            onZoomLevelSelected?(2)
        case (.zoom3, UInt32(kEventHotKeyPressed)):
            onZoomLevelSelected?(3)
        case (.area, UInt32(kEventHotKeyPressed)):
            onAreaPressed?()
        default:
            break
        }
    }
}
