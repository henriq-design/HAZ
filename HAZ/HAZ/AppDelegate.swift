import Cocoa
import CoreGraphics

private func localized(_ key: String, fallback: String) -> String {
    NSLocalizedString(
        key,
        tableName: "Localizable",
        bundle: .main,
        value: fallback,
        comment: ""
    )
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    typealias ActivationMode = HAZPreferences.ActivationMode
    typealias DisplayScope = HAZPreferences.DisplayScope
    typealias ZoomLevel = HAZPreferences.ZoomLevel

    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Event surface for Area guides. In x2/x3 it covers the whole Area to
    /// prevent misleading clicks on scaled content. In x1 the same view is
    /// mounted only on narrow source/guide hit zones, preserving click-through
    /// across the rest of the underlying interface.
    private final class AreaGuideInteractionView: NSView {
        let areaScreenFrame: CGRect
        let fixedAxis: AreaGuideAxis?

        var horizontalGuideY: CGFloat?
        var verticalGuideX: CGFloat?

        var onGuideChanged: ((AreaGuideAxis, CGFloat?) -> Void)?
        var onGuideInteractionChanged: ((AreaGuideAxis?, AreaGuideAxis?) -> Void)?
        var onGuideCommitted: ((AreaGuideAxis, CGFloat?) -> Void)?

        private var hoveredAxis: AreaGuideAxis? {
            didSet {
                guard hoveredAxis != oldValue else { return }
                publishInteractionState()
            }
        }

        private var draggingAxis: AreaGuideAxis? {
            didSet {
                guard draggingAxis != oldValue else { return }
                publishInteractionState()
            }
        }

        private var mouseTrackingArea: NSTrackingArea?

        init(frame frameRect: NSRect, areaScreenFrame: CGRect, fixedAxis: AreaGuideAxis?) {
            self.areaScreenFrame = areaScreenFrame
            self.fixedAxis = fixedAxis
            super.init(frame: frameRect)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let mouseTrackingArea {
                removeTrackingArea(mouseTrackingArea)
            }

            let tracking = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(tracking)
            mouseTrackingArea = tracking
        }

        override func mouseEntered(with event: NSEvent) {
            updateHoverAndCursor(with: event)
        }

        override func mouseMoved(with event: NSEvent) {
            guard draggingAxis == nil else { return }
            updateHoverAndCursor(with: event)
        }

        override func mouseExited(with event: NSEvent) {
            guard draggingAxis == nil else { return }
            hoveredAxis = nil
            NSCursor.arrow.set()
        }

        override func mouseDown(with event: NSEvent) {
            let point = areaPoint(for: event)
            guard let axis = guideAxis(at: point) else { return }

            draggingAxis = axis
            hoveredAxis = axis
            updateCursor(for: axis)
            updateGuide(axis: axis, point: point)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let draggingAxis else { return }
            updateGuide(axis: draggingAxis, point: areaPoint(for: event))
        }

        override func mouseUp(with event: NSEvent) {
            guard let axis = draggingAxis else { return }

            let point = areaPoint(for: event)
            let position = AreaGuideGeometry.clampedPosition(
                for: axis,
                point: point,
                in: areaBounds
            )
            let finalPosition = AreaGuideGeometry.shouldRemove(
                axis: axis,
                position: position,
                in: areaBounds
            ) ? nil : position

            setGuide(axis: axis, position: finalPosition)
            onGuideCommitted?(axis, finalPosition)
            draggingAxis = nil

            hoveredAxis = guideAxis(at: point)
            updateCursor(for: hoveredAxis)
        }

        private var areaBounds: CGRect {
            CGRect(origin: .zero, size: areaScreenFrame.size)
        }

        private func areaPoint(for event: NSEvent) -> CGPoint {
            guard let window else { return .zero }
            let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
            return CGPoint(
                x: screenPoint.x - areaScreenFrame.minX,
                y: screenPoint.y - areaScreenFrame.minY
            )
        }

        private func guideAxis(at point: CGPoint) -> AreaGuideAxis? {
            if let fixedAxis { return fixedAxis }
            return AreaGuideGeometry.preferredAxis(
                at: point,
                in: areaBounds,
                horizontalGuideY: horizontalGuideY,
                verticalGuideX: verticalGuideX
            )
        }

        private func updateGuide(axis: AreaGuideAxis, point: CGPoint) {
            let position = AreaGuideGeometry.clampedPosition(
                for: axis,
                point: point,
                in: areaBounds
            )
            setGuide(axis: axis, position: position)
        }

        private func setGuide(axis: AreaGuideAxis, position: CGFloat?) {
            switch axis {
            case .horizontal:
                horizontalGuideY = position
            case .vertical:
                verticalGuideX = position
            }
            onGuideChanged?(axis, position)
        }

        private func updateHoverAndCursor(with event: NSEvent) {
            let nextAxis = guideAxis(at: areaPoint(for: event))
            hoveredAxis = nextAxis
            updateCursor(for: nextAxis)
        }

        private func updateCursor(for axis: AreaGuideAxis?) {
            switch axis {
            case .horizontal:
                NSCursor.resizeUpDown.set()
            case .vertical:
                NSCursor.resizeLeftRight.set()
            case nil:
                NSCursor.arrow.set()
            }
        }

        private func publishInteractionState() {
            onGuideInteractionChanged?(hoveredAxis, draggingAxis)
        }
    }

    private struct Overlay {
        let screen: NSScreen
        let window: OverlayWindow
        let view: FlashlightView
    }

    private let launchUptime: TimeInterval
    private let preferences: HAZPreferences
    private var preferencesObservation: UUID?
    private let hotKeys = GlobalHotKeyManager()
    private let magnifierCapture = MagnifierCaptureManager()

    private var overlays: [Overlay] = []
    private var cursorTimer: Timer?

    // Presentation state only: the selected preference remains the target.
    private struct MagnifierZoomTransition {
        let from: CGFloat
        let to: CGFloat
        let start: TimeInterval
        let duration: TimeInterval

        func value(at now: TimeInterval) -> CGFloat {
            let progress = CGFloat(min(1, max(0, (now - start) / duration)))
            if progress >= 1 { return to }
            let remaining = 1 - progress
            let eased = 1 - remaining * remaining * remaining
            return from + (to - from) * eased
        }
    }

    private var renderedMagnification: CGFloat = 1.25
    private var magnifierZoomTransition: MagnifierZoomTransition?
    private var awaitingInitialMagnifierFrame = false
    private var statusItem: NSStatusItem!
    private var toggleMenuItem: NSMenuItem!
    private var areaMenuItem: NSMenuItem!
    private var holdModeItem: NSMenuItem!
    private var toggleModeItem: NSMenuItem!
    private var currentDisplayItem: NSMenuItem!
    private var allDisplaysItem: NSMenuItem!
    private var zoomItems: [NSMenuItem] = []
    private var sizeItems: [NSMenuItem] = []
    private var darknessItems: [NSMenuItem] = []
    private var screenPermissionMenuItem: NSMenuItem!
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?

    /// The app starts with no active tool. Overlay windows are prepared at
    /// launch so Magnifier and Area can respond immediately to global shortcuts.
    private var activeTool: HAZTool?
    private var isActive: Bool { activeTool != nil }
    private var isScreenCaptureInUse: Bool {
        activeTool == .magnifier || (activeTool == .area && areaLevel.requiresCapture)
    }
    private var hotKeyIsPhysicallyDown = false
    private var magnifierDisplayID: CGDirectDisplayID?
    private var lastPresentedFrameSequence: UInt64 = 0
    private var zoomHUDWorkItem: DispatchWorkItem?
    private var areaHUDWorkItem: DispatchWorkItem?
    private var areaLevel: AreaLevel = .x1
    private var areaDisplayID: CGDirectDisplayID?
    private var areaCaptureTimer: Timer?
    private var areaInteractionWindows: [OverlayWindow] = []
    private var areaHorizontalGuideY: CGFloat?
    private var areaVerticalGuideX: CGFloat?
    private var didShowCaptureFailureHelp = false
    private let screenPermission = ScreenCapturePermission()
    private var captureFailedForSession = false
    private var screenCaptureBlockedForSession = false

    private var activationMode: ActivationMode {
        get { preferences.activationMode }
        set { preferences.activationMode = newValue }
    }

    private var displayScope: DisplayScope {
        get { preferences.displayScope }
        set { preferences.displayScope = newValue }
    }

    private var circleRadius: CGFloat {
        get { preferences.circleRadius }
        set { preferences.circleRadius = newValue }
    }

    private var dimAlpha: CGFloat {
        get { preferences.dimAlpha }
        set { preferences.dimAlpha = newValue }
    }

    private var zoomLevel: ZoomLevel {
        get { preferences.zoomLevel }
        set { preferences.zoomLevel = newValue }
    }

    init(launchUptime: TimeInterval) {
        self.launchUptime = launchUptime
        self.preferences = HAZPreferences()
        super.init()
        preferencesObservation = preferences.observe { [weak self] change in
            self?.preferenceDidChange(change)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchMS = (ProcessInfo.processInfo.systemUptime - launchUptime) * 1_000
        print("[HAZ] applicationDidFinishLaunching in \(formatMS(launchMS)) ms")
        print("[HAZ] screens: \(NSScreen.screens.count)")

        setupStatusItem()
        rebuildOverlayWindows()
        configureHotKeys()
        configureMagnifierCapture()
        logScreenCaptureState(prefix: "launch")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        print("[HAZ] magnifier default: \(zoomLevel.hudTitle) (\(formatZoom(zoomLevel.magnification))x optical scale)")
        print("[HAZ] Preparada (inactiva)")
        #if DEBUG
        runCaptureDiagnosticIfRequested()
        let isDiagnosticLaunch = ProcessInfo.processInfo.arguments.contains("--diagnose-capture")
            || ProcessInfo.processInfo.arguments.contains("--diagnose-controls")
        if !isDiagnosticLaunch {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboardingIfNeeded()
            }
        }
        #else
        DispatchQueue.main.async { [weak self] in
            self?.showOnboardingIfNeeded()
        }
        #endif
    }

    // MARK: - Preferences

    private func preferenceDidChange(_ change: HAZPreferences.Change) {
        switch change {
        case .activationMode:
            if activationMode == .hold, activeTool == .magnifier {
                deactivateMagnifier(reason: "mode changed")
            } else {
                updateOverlayInteractionState()
                updateMenuState()
            }

        case .displayScope:
            updateMenuState()
            if activeTool == .magnifier { updateCirclePosition() }

        case .circleRadius:
            overlays.forEach { $0.view.circleRadius = circleRadius }
            updateMenuState()

        case .dimAlpha:
            overlays.forEach { $0.view.dimAlpha = dimAlpha }
            updateMenuState()

        case .zoomLevel:
            if activeTool == .magnifier {
                if !awaitingInitialMagnifierFrame {
                    beginMagnifierZoom(to: zoomLevel.magnification)
                }
            } else {
                resetMagnifierZoom(to: zoomLevel.magnification)
            }
            updateMenuState()
        }
    }

    // MARK: - Overlay windows

    private func rebuildOverlayWindows() {
        print("[HAZ] rebuilding overlays for \(NSScreen.screens.count) screen(s)")

        overlays.forEach { $0.window.close() }
        overlays.removeAll()

        for screen in NSScreen.screens {
            let view = FlashlightView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.circleRadius = circleRadius
            view.dimAlpha = dimAlpha
            view.magnification = activeTool == .magnifier ? renderedMagnification : zoomLevel.magnification

            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )

            window.setFrame(screen.frame, display: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.acceptsMouseMovedEvents = true
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false

            // Stay above ordinary application windows, but below the menu bar.
            // This makes the status item remain easy to reach even while active.
            window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)

            var behavior: NSWindow.CollectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .ignoresCycle,
                .stationary
            ]

            if #available(macOS 26.0, *) {
                behavior.insert(.canJoinAllApplications)
            }

            window.collectionBehavior = behavior
            window.contentView = view
            view.onAreaSelectionCompleted = { [weak self, weak window] rect in
                self?.completeAreaSelection(rect, on: screen, window: window)
            }
            window.makeFirstResponder(view)
            window.orderOut(nil)

            overlays.append(Overlay(screen: screen, window: window, view: view))
            print("[HAZ] overlay prepared: \(screen.localizedName) \(screen.frame)")
        }

        updateOverlayInteractionState()

        if activeTool == .magnifier {
            updateCirclePosition()
        }
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        deactivateActiveTool(reason: "screen parameters changed")
        rebuildOverlayWindows()
    }

    /// Magnifier and a completed Area are click-through. Area only captures
    /// pointer events during the drag used to define a new selection.
    private func updateOverlayInteractionState() {
        overlays.forEach { overlay in
            let receivesAreaDrag = activeTool == .area && overlay.view.isAreaSelectionArmed
            overlay.window.ignoresMouseEvents = !receivesAreaDrag
        }
    }

    // MARK: - Activation

    private func configureHotKeys() {
        hotKeys.onMagnifierPressed = { [weak self] in
            DispatchQueue.main.async {
                self?.magnifierShortcutPressed()
            }
        }

        hotKeys.onMagnifierReleased = { [weak self] in
            DispatchQueue.main.async {
                self?.magnifierShortcutReleased()
            }
        }

        hotKeys.onEscapePressed = { [weak self] in
            DispatchQueue.main.async {
                self?.deactivateActiveTool(reason: "Escape")
            }
        }

        hotKeys.onAreaPressed = { [weak self] in
            DispatchQueue.main.async {
                self?.activateAreaSelection(reason: "⌃⌥A")
            }
        }

        hotKeys.onZoomLevelSelected = { [weak self] level in
            DispatchQueue.main.async {
                guard let self else { return }

                if self.activeTool == .area {
                    self.setAreaLevel(
                        AreaLevel.at(index: level - 1),
                        source: "hotkey"
                    )
                    return
                }

                self.setZoomLevel(
                    ZoomLevel.at(index: level - 1),
                    source: "hotkey",
                    showHUD: self.activeTool == .magnifier
                )
            }
        }

        _ = hotKeys.registerMagnifier()
        _ = hotKeys.registerArea()
        hotKeys.registerZoomLevels()
    }

    private func magnifierShortcutPressed() {
        guard !hotKeyIsPhysicallyDown else { return }
        hotKeyIsPhysicallyDown = true

        switch activationMode {
        case .hold:
            activateMagnifier(reason: "⌃⌥F hold")
        case .toggle:
            if activeTool == .magnifier {
                deactivateMagnifier(reason: "⌃⌥F toggle")
            } else {
                activateMagnifier(reason: "⌃⌥F toggle")
            }
        }
    }

    private func magnifierShortcutReleased() {
        hotKeyIsPhysicallyDown = false
        updateOverlayInteractionState()

        if activationMode == .hold, activeTool == .magnifier {
            deactivateMagnifier(reason: "⌃⌥F released")
        }
    }

    private func activateMagnifier(reason: String) {
        if activeTool == .magnifier { return }
        if activeTool != nil {
            deactivateActiveTool(reason: "switch to magnifier")
        }

        guard !captureFailedForSession else {
            hotKeyIsPhysicallyDown = false
            return
        }
        guard ensureScreenCaptureAccessForActivation() else { return }

        let start = ProcessInfo.processInfo.systemUptime
        guard hotKeys.registerEscape() else {
            hotKeyIsPhysicallyDown = false
            print("[HAZ] No se activa la lupa: Escape no está disponible")
            return
        }

        activeTool = .magnifier
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        resetMagnifierZoom(to: reduceMotion ? zoomLevel.magnification : 1.0)
        awaitingInitialMagnifierFrame = !reduceMotion
        overlays.forEach { overlay in
            overlay.view.activeTool = .magnifier
            overlay.view.areaSelectionRect = nil
            overlay.view.isAreaSelectionArmed = false
        }
        updateOverlayInteractionState()
        updateCirclePosition()
        startCursorTracking()
        updateMenuState()

        let elapsedMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        print("[HAZ] magnifier activated (\(reason)) in \(formatMS(elapsedMS)) ms · zoom \(zoomLevel.hudTitle)")
    }

    private func deactivateMagnifier(reason: String) {
        guard activeTool == .magnifier else { return }

        activeTool = nil
        // Preserve immediate exit for Escape, hold release and tool switching.
        resetMagnifierZoom(to: zoomLevel.magnification)
        zoomHUDWorkItem?.cancel()
        zoomHUDWorkItem = nil
        stopCursorTracking()
        stopMagnifierCapture()
        hotKeys.unregisterEscape()
        hotKeyIsPhysicallyDown = false

        overlays.forEach { overlay in
            overlay.window.ignoresMouseEvents = true
            overlay.view.activeTool = nil
            overlay.view.circleCenter = nil
            overlay.view.capturedFrame = nil
            overlay.view.zoomHUDText = nil
            overlay.window.orderOut(nil)
        }
        updateMenuState()

        print("[HAZ] magnifier deactivated (\(reason))")
    }

    // MARK: - Area

    private func activateAreaSelection(reason: String) {
        if activeTool == .magnifier {
            deactivateMagnifier(reason: "switch to area")
        }

        if activeTool != .area {
            guard hotKeys.registerEscape() else {
                print("[HAZ] No se activa Area: Escape no está disponible")
                return
            }
            activeTool = .area
        }

        resetAreaState(stopCapture: true)
        areaDisplayID = nil
        stopCursorTracking()

        let mouseLocation = NSEvent.mouseLocation
        guard let target = overlays.first(where: { $0.screen.frame.contains(mouseLocation) }) ?? overlays.first else {
            activeTool = nil
            hotKeys.unregisterEscape()
            return
        }

        for overlay in overlays {
            let isTarget = overlay.window === target.window
            overlay.view.activeTool = isTarget ? .area : nil
            overlay.view.circleCenter = nil
            overlay.view.capturedFrame = nil
            overlay.view.zoomHUDText = nil
            overlay.view.areaSelectionRect = nil
            overlay.view.areaMagnification = 1.0
            overlay.view.areaHUDText = nil
            overlay.view.areaHorizontalGuideY = nil
            overlay.view.areaVerticalGuideX = nil
            overlay.view.areaHoveredGuideAxis = nil
            overlay.view.areaDraggingGuideAxis = nil
            overlay.view.isAreaSelectionArmed = isTarget
            overlay.window.ignoresMouseEvents = !isTarget

            if isTarget {
                overlay.window.orderFrontRegardless()
            } else {
                overlay.window.orderOut(nil)
            }
        }

        updateOverlayInteractionState()
        updateMenuState()
        NSCursor.crosshair.set()
        print("[HAZ] area ready (\(reason)) · drag to select")
    }

    private func completeAreaSelection(_ rect: CGRect, on screen: NSScreen, window: NSWindow?) {
        guard activeTool == .area,
              AreaSelectionGeometry.isMeaningful(rect),
              let window,
              let displayID = MagnifierCaptureManager.displayID(for: screen) else { return }

        areaDisplayID = displayID
        areaLevel = .x1
        window.ignoresMouseEvents = true

        overlays.forEach { overlay in
            overlay.view.areaMagnification = 1.0
            overlay.view.areaHUDText = nil
            overlay.view.areaHorizontalGuideY = nil
            overlay.view.areaVerticalGuideX = nil
            overlay.view.capturedFrame = nil
            if overlay.window !== window {
                overlay.window.orderOut(nil)
            }
        }

        NSCursor.arrow.set()
        refreshAreaInteractionWindows()
        updateMenuState()

        print(
            "[HAZ] area selected on \(screen.localizedName): " +
            "\(Int(rect.width))×\(Int(rect.height)) pt · Area x1"
        )
    }

    private func setAreaLevel(_ level: AreaLevel, source: String) {
        guard activeTool == .area else { return }
        guard let overlay = selectedAreaOverlay(),
              let rect = overlay.view.areaSelectionRect,
              AreaSelectionGeometry.isMeaningful(rect) else {
            print("[HAZ] Area: selecciona una región antes de usar x1/x2/x3")
            return
        }

        if level == .x1 {
            let wasScaled = areaLevel.requiresCapture
            areaLevel = .x1
            stopAreaCaptureTracking()
            if wasScaled {
                stopMagnifierCapture()
            }

            overlay.view.areaMagnification = 1.0
            overlay.view.capturedFrame = nil
            refreshAreaInteractionWindows()
            showAreaHUD(localized("area.hud.x1", fallback: "Área · x1"))
            updateOverlayInteractionState()
            updateMenuState()
            print("[HAZ] Area x1 · 1:1 via \(source) · click-through salvo Guías")
            return
        }

        guard !captureFailedForSession else {
            print("[HAZ] Area x\(level.rawValue) no disponible: captura bloqueada para esta sesión")
            return
        }
        guard ensureScreenCaptureAccessForActivation() else {
            print("[HAZ] Area x\(level.rawValue) requiere Grabación de pantalla")
            return
        }

        let wasScaled = areaLevel.requiresCapture
        areaLevel = level
        overlay.view.areaMagnification = level.magnification

        if !wasScaled {
            updateMagnifierCapture(for: overlay.screen)
            startAreaCaptureTracking()
        }

        refreshAreaInteractionWindows()
        showAreaHUD(
            level == .x2
                ? localized("area.hud.x2", fallback: "Área · x2")
                : localized("area.hud.x3", fallback: "Área · x3")
        )
        updateMenuState()

        print(
            "[HAZ] Area x\(level.rawValue) " +
            "(\(formatZoom(level.magnification))x) via \(source) · región ampliada no interactiva"
        )
    }

    private func selectedAreaOverlay() -> Overlay? {
        guard let areaDisplayID else { return nil }
        return overlays.first { overlay in
            MagnifierCaptureManager.displayID(for: overlay.screen) == areaDisplayID &&
            overlay.view.activeTool == .area &&
            overlay.view.areaSelectionRect != nil
        }
    }

    private func startAreaCaptureTracking() {
        guard areaCaptureTimer == nil else { return }

        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(areaCaptureTick(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        areaCaptureTimer = timer
    }

    private func stopAreaCaptureTracking() {
        areaCaptureTimer?.invalidate()
        areaCaptureTimer = nil
    }

    @objc private func areaCaptureTick(_ timer: Timer) {
        guard activeTool == .area,
              areaLevel.requiresCapture,
              let areaDisplayID,
              let overlay = selectedAreaOverlay(),
              let frame = magnifierCapture.latestFrame(),
              frame.displayID == areaDisplayID,
              frame.sequence != lastPresentedFrameSequence else { return }

        overlay.view.capturedFrame = frame.image
        lastPresentedFrameSequence = frame.sequence
    }

    private func refreshAreaInteractionWindows() {
        destroyAreaInteractionWindows()

        guard activeTool == .area,
              let overlay = selectedAreaOverlay(),
              let rect = overlay.view.areaSelectionRect,
              AreaSelectionGeometry.isMeaningful(rect) else { return }

        let areaScreenRect = overlay.window.convertToScreen(rect)

        overlay.view.areaHorizontalGuideY = areaHorizontalGuideY
        overlay.view.areaVerticalGuideX = areaVerticalGuideX
        overlay.view.areaHoveredGuideAxis = nil
        overlay.view.areaDraggingGuideAxis = nil

        if areaLevel.requiresCapture {
            let window = makeAreaInteractionWindow(
                screenFrame: areaScreenRect,
                areaScreenFrame: areaScreenRect,
                overlay: overlay,
                fixedAxis: nil
            )
            areaInteractionWindows = [window]
        } else {
            var windows: [OverlayWindow] = []

            if let y = areaHorizontalGuideY {
                let centerY = areaScreenRect.minY + y
                let minY = max(areaScreenRect.minY, centerY - AreaGuideGeometry.hitTolerance)
                let maxY = min(areaScreenRect.maxY, centerY + AreaGuideGeometry.hitTolerance)
                let hitFrame = CGRect(
                    x: areaScreenRect.minX,
                    y: minY,
                    width: areaScreenRect.width,
                    height: max(maxY - minY, 1)
                )
                windows.append(
                    makeAreaInteractionWindow(
                        screenFrame: hitFrame,
                        areaScreenFrame: areaScreenRect,
                        overlay: overlay,
                        fixedAxis: .horizontal
                    )
                )
            } else {
                let sourceFrame = CGRect(
                    x: areaScreenRect.minX,
                    y: max(areaScreenRect.minY, areaScreenRect.maxY - AreaGuideGeometry.sourceInset),
                    width: areaScreenRect.width,
                    height: min(AreaGuideGeometry.sourceInset, areaScreenRect.height)
                )
                windows.append(
                    makeAreaInteractionWindow(
                        screenFrame: sourceFrame,
                        areaScreenFrame: areaScreenRect,
                        overlay: overlay,
                        fixedAxis: .horizontal
                    )
                )
            }

            if let x = areaVerticalGuideX {
                let centerX = areaScreenRect.minX + x
                let minX = max(areaScreenRect.minX, centerX - AreaGuideGeometry.hitTolerance)
                let maxX = min(areaScreenRect.maxX, centerX + AreaGuideGeometry.hitTolerance)
                let hitFrame = CGRect(
                    x: minX,
                    y: areaScreenRect.minY,
                    width: max(maxX - minX, 1),
                    height: areaScreenRect.height
                )
                windows.append(
                    makeAreaInteractionWindow(
                        screenFrame: hitFrame,
                        areaScreenFrame: areaScreenRect,
                        overlay: overlay,
                        fixedAxis: .vertical
                    )
                )
            } else {
                let sourceFrame = CGRect(
                    x: areaScreenRect.minX,
                    y: areaScreenRect.minY,
                    width: min(AreaGuideGeometry.sourceInset, areaScreenRect.width),
                    height: areaScreenRect.height
                )
                windows.append(
                    makeAreaInteractionWindow(
                        screenFrame: sourceFrame,
                        areaScreenFrame: areaScreenRect,
                        overlay: overlay,
                        fixedAxis: .vertical
                    )
                )
            }

            areaInteractionWindows = windows
        }

        areaInteractionWindows.forEach { $0.orderFrontRegardless() }
        overlay.window.orderFrontRegardless()
    }

    private func makeAreaInteractionWindow(
        screenFrame: CGRect,
        areaScreenFrame: CGRect,
        overlay: Overlay,
        fixedAxis: AreaGuideAxis?
    ) -> OverlayWindow {
        let window = OverlayWindow(
            contentRect: screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: overlay.screen
        )
        window.setFrame(screenFrame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.level = overlay.window.level
        window.collectionBehavior = overlay.window.collectionBehavior

        let interactionView = AreaGuideInteractionView(
            frame: NSRect(origin: .zero, size: screenFrame.size),
            areaScreenFrame: areaScreenFrame,
            fixedAxis: fixedAxis
        )
        interactionView.horizontalGuideY = areaHorizontalGuideY
        interactionView.verticalGuideX = areaVerticalGuideX

        interactionView.onGuideChanged = { [weak self, weak view = overlay.view] axis, position in
            guard let self, let view else { return }

            switch axis {
            case .horizontal:
                self.areaHorizontalGuideY = position
                view.areaHorizontalGuideY = position
            case .vertical:
                self.areaVerticalGuideX = position
                view.areaVerticalGuideX = position
            }
        }

        interactionView.onGuideInteractionChanged = { [weak view = overlay.view] hovered, dragging in
            view?.areaHoveredGuideAxis = hovered
            view?.areaDraggingGuideAxis = dragging
        }

        interactionView.onGuideCommitted = { [weak self] axis, position in
            let orientation = axis == .horizontal ? "horizontal" : "vertical"
            if position == nil {
                print("[HAZ] guía \(orientation) eliminada")
            } else {
                print("[HAZ] guía \(orientation) colocada")
            }

            DispatchQueue.main.async {
                self?.refreshAreaInteractionWindows()
            }
        }

        window.contentView = interactionView
        return window
    }

    private func destroyAreaInteractionWindows() {
        areaInteractionWindows.forEach { window in
            window.orderOut(nil)
            window.close()
        }
        areaInteractionWindows.removeAll()

        selectedAreaOverlay()?.view.areaHoveredGuideAxis = nil
        selectedAreaOverlay()?.view.areaDraggingGuideAxis = nil
        NSCursor.arrow.set()
    }

    private func resetAreaGuides() {
        areaHorizontalGuideY = nil
        areaVerticalGuideX = nil

        overlays.forEach { overlay in
            overlay.view.areaHorizontalGuideY = nil
            overlay.view.areaVerticalGuideX = nil
            overlay.view.areaHoveredGuideAxis = nil
            overlay.view.areaDraggingGuideAxis = nil
        }
    }

    private func showAreaHUD(_ text: String) {
        areaHUDWorkItem?.cancel()
        areaHUDWorkItem = nil

        guard let overlay = selectedAreaOverlay() else { return }
        overlay.view.areaHUDText = text

        let workItem = DispatchWorkItem { [weak self] in
            self?.selectedAreaOverlay()?.view.areaHUDText = nil
        }
        areaHUDWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.70, execute: workItem)
    }

    private func resetAreaState(stopCapture: Bool) {
        areaHUDWorkItem?.cancel()
        areaHUDWorkItem = nil
        stopAreaCaptureTracking()
        destroyAreaInteractionWindows()
        resetAreaGuides()
        areaLevel = .x1

        if stopCapture {
            stopMagnifierCapture()
        }

        overlays.forEach { overlay in
            overlay.view.areaMagnification = 1.0
            overlay.view.areaHUDText = nil
            overlay.view.capturedFrame = nil
        }
    }

    private func deactivateArea(reason: String) {
        guard activeTool == .area else { return }

        resetAreaState(stopCapture: true)
        activeTool = nil
        areaDisplayID = nil
        hotKeys.unregisterEscape()
        NSCursor.arrow.set()

        overlays.forEach { overlay in
            overlay.window.ignoresMouseEvents = true
            overlay.view.activeTool = nil
            overlay.view.isAreaSelectionArmed = false
            overlay.view.areaSelectionRect = nil
            overlay.window.orderOut(nil)
        }

        updateMenuState()
        print("[HAZ] area deactivated (\(reason))")
    }

    private func deactivateActiveTool(reason: String) {
        switch activeTool {
        case .magnifier:
            deactivateMagnifier(reason: reason)
        case .area:
            deactivateArea(reason: reason)
        case nil:
            break
        }
    }

    // MARK: - Cursor tracking

    private func startCursorTracking() {
        guard cursorTimer == nil else { return }

        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(cursorTick(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        cursorTimer = timer
    }

    private func stopCursorTracking() {
        cursorTimer?.invalidate()
        cursorTimer = nil
    }

    @objc private func cursorTick(_ timer: Timer) {
        updateCirclePosition()
    }

    private func updateCirclePosition() {
        guard activeTool == .magnifier else { return }

        let mouseLocation = NSEvent.mouseLocation
        let activeOverlay = overlays.first(where: { $0.screen.frame.contains(mouseLocation) })

        if let activeOverlay {
            updateMagnifierCapture(for: activeOverlay.screen)
        }

        // Start activation motion only when the first usable frame is ready.
        // A display crossing does not restart the animation or the capture clock.
        if awaitingInitialMagnifierFrame {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                resetMagnifierZoom(to: zoomLevel.magnification)
            } else if let displayID = magnifierDisplayID,
                      let frame = magnifierCapture.latestFrame(),
                      frame.displayID == displayID {
                awaitingInitialMagnifierFrame = false
                beginMagnifierZoom(to: zoomLevel.magnification)
            }
        }
        advanceMagnifierZoom(at: ProcessInfo.processInfo.systemUptime)

        for overlay in overlays {
            let containsMouse = overlay.screen.frame.contains(mouseLocation)

            if containsMouse {
                let windowPoint = overlay.window.convertPoint(fromScreen: mouseLocation)
                let viewPoint = overlay.view.convert(windowPoint, from: nil)
                overlay.view.circleCenter = viewPoint
                if let displayID = MagnifierCaptureManager.displayID(for: overlay.screen),
                   let frame = magnifierCapture.latestFrame(),
                   frame.displayID == displayID,
                   frame.sequence != lastPresentedFrameSequence {
                    overlay.view.capturedFrame = frame.image
                    lastPresentedFrameSequence = frame.sequence
                }

                overlay.window.orderFrontRegardless()
            } else {
                overlay.view.circleCenter = nil
                overlay.view.capturedFrame = nil
                overlay.view.zoomHUDText = nil

                switch displayScope {
                case .current:
                    overlay.window.orderOut(nil)
                case .all:
                    overlay.window.orderFrontRegardless()
                }
            }
        }
    }

    // MARK: - Magnifier

    private func configureMagnifierCapture() {
        magnifierCapture.onCaptureReady = { [weak self] displayID, elapsedMS in
            guard let self else { return }
            self.didShowCaptureFailureHelp = false
            print("[HAZ] Captura lista for display \(displayID) in \(self.formatMS(elapsedMS)) ms")
        }

        magnifierCapture.onCaptureError = { [weak self] error in
            guard let self else { return }
            print("[HAZ] Error de captura: \((error as NSError).domain) / \((error as NSError).code): \(error.localizedDescription)")
            self.handleScreenCaptureFailure(error)
        }
    }

    private func updateMagnifierCapture(for screen: NSScreen) {
        guard let displayID = MagnifierCaptureManager.displayID(for: screen) else {
            return
        }

        if magnifierDisplayID != displayID {
            magnifierDisplayID = displayID
            lastPresentedFrameSequence = 0
            overlays.forEach { $0.view.capturedFrame = nil }
        }

        magnifierCapture.start(for: screen)
    }

    private func stopMagnifierCapture() {
        magnifierCapture.stop()
        magnifierDisplayID = nil
        lastPresentedFrameSequence = 0
        overlays.forEach { $0.view.capturedFrame = nil }
    }

    private func ensureScreenCaptureAccessForActivation() -> Bool {
        let granted = screenPermission.ensureAccess()
        screenCaptureBlockedForSession = !granted
        if granted {
            didShowCaptureFailureHelp = false
        } else {
            print("[HAZ] Permiso denegado: captura bloqueada, sin reintento automático")
            // El menú permite abrir Ajustes sin encadenar otro diálogo al de macOS.
            hotKeyIsPhysicallyDown = false
        }
        updateMenuState()
        return granted
    }

    private func showScreenCapturePermissionHelpIfNeeded() {
        guard !didShowCaptureFailureHelp else { return }
        didShowCaptureFailureHelp = true

        let alert = NSAlert()
        alert.messageText = localized("permission.required.title", fallback: "Lupa y Área x2/x3 necesitan Grabación de pantalla")
        alert.informativeText = localized("permission.required.body", fallback: "HAZ solo necesita capturar la pantalla al usar Lupa o ampliar un Área a x2/x3. Concede acceso en Privacidad y seguridad > Grabación de pantalla y audio del sistema. Área x1 y sus Guías seguirán funcionando sin este permiso.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: localized("permission.openSettings", fallback: "Abrir Ajustes"))
        alert.addButton(withTitle: localized("common.close", fallback: "Cerrar"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openScreenCaptureSettings()
        }
    }

    private func handleScreenCaptureFailure(_ error: Error) {
        // A stream failure is terminal for this capture session. Stop first so
        // no pending/repeated requests can race with the fallback UI.
        captureFailedForSession = true
        stopMagnifierCapture()
        screenCaptureBlockedForSession = !CGPreflightScreenCaptureAccess()

        if activeTool == .magnifier {
            deactivateMagnifier(reason: "Screen capture unavailable")
        } else if activeTool == .area, areaLevel.requiresCapture {
            areaLevel = .x1
            stopAreaCaptureTracking()
            destroyAreaInteractionWindows()
            overlays.forEach { overlay in
                overlay.view.areaMagnification = 1.0
                overlay.view.capturedFrame = nil
            }
            refreshAreaInteractionWindows()
            showAreaHUD(localized("area.hud.x1", fallback: "Área · x1"))
            updateOverlayInteractionState()
            updateMenuState()
            print("[HAZ] Area ampliada no disponible · vuelve a Area x1")
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--diagnose-capture") || ProcessInfo.processInfo.arguments.contains("--diagnose-controls") { return }
        #endif
        guard !didShowCaptureFailureHelp else { return }
        didShowCaptureFailureHelp = true

        let alert = NSAlert()
        alert.messageText = localized("permission.captureFailed.title", fallback: "HAZ no puede capturar esta pantalla")

        if CGPreflightScreenCaptureAccess() {
            alert.informativeText = localized(
                "permission.captureFailed.grantedBody",
                fallback: "macOS indica que HAZ tiene permiso, pero ScreenCaptureKit no ha podido iniciar la captura necesaria para Lupa o Área x2/x3. Usa «Revisar captura y permiso…» para habilitar un nuevo intento o cierra y vuelve a abrir HAZ."
            )
        } else {
            alert.informativeText = localized(
                "permission.captureFailed.deniedBody",
                fallback: "macOS está rechazando Grabación de pantalla para esta compilación. Lupa y Área x2/x3 no podrán ampliar contenido hasta que habilites HAZ en Ajustes y vuelvas a abrir la app."
            )
        }

        alert.alertStyle = .warning
        alert.addButton(withTitle: localized("permission.openSettings", fallback: "Abrir Ajustes"))
        alert.addButton(withTitle: localized("common.close", fallback: "Cerrar"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openScreenCaptureSettings()
        }
    }

    private func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func logScreenCaptureState(prefix: String) {
        let bundleID = Bundle.main.bundleIdentifier ?? "<nil>"
        let executable = Bundle.main.executableURL?.path ?? "<nil>"
        let granted = CGPreflightScreenCaptureAccess()
        print("[HAZ] \(prefix) identity: bundle=\(bundleID)")
        print("[HAZ] \(prefix) executable: \(executable)")
        print("[HAZ] \(prefix) Screen Recording preflight: \(granted ? "granted" : "denied")")
    }

    @objc private func reviewScreenCapturePermission(_ sender: Any?) {
        logScreenCaptureState(prefix: "revisión manual")
        guard !isScreenCaptureInUse else { return }
        magnifierCapture.resetFailure()
        captureFailedForSession = false

        if CGPreflightScreenCaptureAccess() {
            screenCaptureBlockedForSession = false
            didShowCaptureFailureHelp = false

            let alert = NSAlert()
            alert.messageText = localized("permission.granted.title", fallback: "Permiso concedido")
            alert.informativeText = localized("permission.granted.body", fallback: "HAZ tiene acceso a Grabación de pantalla. Ya puedes usar Lupa y Área x2/x3.")
            alert.addButton(withTitle: localized("common.ok", fallback: "OK"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        } else {
            screenCaptureBlockedForSession = true
            didShowCaptureFailureHelp = false
            showScreenCapturePermissionHelpIfNeeded()
        }

        updateMenuState()
    }

    private func areaMenuTitle(for level: AreaLevel) -> String {
        switch level {
        case .x1:
            return localized("area.zoom.x1", fallback: "Área x1 · 1:1")
        case .x2:
            return localized("area.zoom.x2", fallback: "Área x2 · Medio")
        case .x3:
            return localized("area.zoom.x3", fallback: "Área x3 · Máximo")
        }
    }

    // MARK: - Zoom

    private func presentMagnifierZoom(_ scale: CGFloat) {
        renderedMagnification = scale
        for overlay in overlays where overlay.view.magnification != scale {
            overlay.view.magnification = scale
        }
    }

    private func resetMagnifierZoom(to scale: CGFloat) {
        awaitingInitialMagnifierFrame = false
        magnifierZoomTransition = nil
        presentMagnifierZoom(scale)
    }

    private func beginMagnifierZoom(to target: CGFloat) {
        let now = ProcessInfo.processInfo.systemUptime
        advanceMagnifierZoom(at: now)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              renderedMagnification != target else {
            resetMagnifierZoom(to: target)
            return
        }
        magnifierZoomTransition = MagnifierZoomTransition(
            from: renderedMagnification,
            to: target,
            start: now,
            duration: target > renderedMagnification ? 0.18 : 0.12
        )
    }

    private func advanceMagnifierZoom(at now: TimeInterval) {
        guard let transition = magnifierZoomTransition else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || now - transition.start >= transition.duration {
            resetMagnifierZoom(to: transition.to)
        } else {
            presentMagnifierZoom(transition.value(at: now))
        }
    }

    private func setZoomLevel(_ level: ZoomLevel, source: String, showHUD: Bool) {
        zoomLevel = level
        print("[HAZ] zoom \(level.hudTitle) (\(formatZoom(level.magnification))x optical scale) via \(source)")
        if showHUD { showZoomHUD() }
    }

    private func showZoomHUD() {
        guard activeTool == .magnifier else { return }

        zoomHUDWorkItem?.cancel()
        overlays.forEach { overlay in
            overlay.view.zoomHUDText = overlay.view.circleCenter == nil ? nil : zoomLevel.hudTitle
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.overlays.forEach { $0.view.zoomHUDText = nil }
        }
        zoomHUDWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: workItem)
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.toolTip = localized("status.inactive", fallback: "HAZ · lista · ⌃⌥F / ⌃⌥A")
        }

        let menu = NSMenu()

        toggleMenuItem = NSMenuItem(
            title: localized("magnifier.enable", fallback: "Activar lupa"),
            action: #selector(toggleMagnifierFromMenu(_:)),
            keyEquivalent: ""
        )
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        areaMenuItem = NSMenuItem(
            title: localized("area.enable", fallback: "Seleccionar área"),
            action: #selector(toggleAreaFromMenu(_:)),
            keyEquivalent: ""
        )
        areaMenuItem.target = self
        menu.addItem(areaMenuItem)

        let shortcutItem = NSMenuItem(title: localized("menu.shortcut", fallback: "Lupa: ⌃⌥F"), action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)

        let areaShortcutItem = NSMenuItem(title: localized("menu.areaShortcut", fallback: "Área: ⌃⌥A"), action: nil, keyEquivalent: "")
        areaShortcutItem.isEnabled = false
        menu.addItem(areaShortcutItem)

        screenPermissionMenuItem = NSMenuItem(
            title: localized("menu.permission", fallback: "Revisar permiso de pantalla para Lupa/Área…"),
            action: #selector(reviewScreenCapturePermission(_:)),
            keyEquivalent: ""
        )
        screenPermissionMenuItem.target = self
        menu.addItem(screenPermissionMenuItem)

        menu.addItem(.separator())
        menu.addItem(makeZoomMenuItem())
        menu.addItem(makeModeMenuItem())
        menu.addItem(makeSizeMenuItem())
        menu.addItem(makeDarknessMenuItem())
        menu.addItem(makeDisplayMenuItem())

        menu.addItem(.separator())

        let gestureInfo = NSMenuItem(
            title: localized("menu.clickThroughInfo", fallback: "Área x1: clics disponibles fuera de Guías"),
            action: nil,
            keyEquivalent: ""
        )
        gestureInfo.isEnabled = false
        menu.addItem(gestureInfo)

        let zoomShortcutInfo = NSMenuItem(
            title: localized("menu.zoomShortcutInfo", fallback: "Niveles: ⌃⌥1 / ⌃⌥2 / ⌃⌥3"),
            action: nil,
            keyEquivalent: ""
        )
        zoomShortcutInfo.isEnabled = false
        menu.addItem(zoomShortcutInfo)

        let escapeInfo = NSMenuItem(title: localized("menu.escapeInfo", fallback: "Esc cierra la herramienta activa"), action: nil, keyEquivalent: "")
        escapeInfo.isEnabled = false
        menu.addItem(escapeInfo)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: localized("menu.settings", fallback: "Ajustes…"),
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: localized("menu.quit", fallback: "Salir de HAZ"),
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateMenuState()
    }

    private func makeZoomMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: localized("menu.zoom", fallback: "Zoom"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: localized("menu.zoom", fallback: "Zoom"))

        zoomItems = ZoomLevel.allCases.enumerated().map { index, level in
            let item = NSMenuItem(
                title: level.menuTitle,
                action: #selector(selectZoomLevel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            submenu.addItem(item)
            return item
        }

        parent.submenu = submenu
        return parent
    }

    private func makeModeMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: localized("menu.activation", fallback: "Activación"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: localized("menu.activation", fallback: "Activación"))

        holdModeItem = NSMenuItem(
            title: localized("activation.hold", fallback: "Mantener"),
            action: #selector(selectHoldMode(_:)),
            keyEquivalent: ""
        )
        holdModeItem.target = self
        submenu.addItem(holdModeItem)

        toggleModeItem = NSMenuItem(
            title: localized("activation.toggle", fallback: "Alternar"),
            action: #selector(selectToggleMode(_:)),
            keyEquivalent: ""
        )
        toggleModeItem.target = self
        submenu.addItem(toggleModeItem)

        parent.submenu = submenu
        return parent
    }

    private func makeSizeMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: localized("menu.size", fallback: "Tamaño"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: localized("menu.size", fallback: "Tamaño"))

        let values: [(String, Int)] = [
            (localized("size.small", fallback: "Pequeño"), 100),
            (localized("size.medium", fallback: "Medio"), 140),
            (localized("size.large", fallback: "Grande"), 200)
        ]

        sizeItems = values.map { title, radius in
            let item = NSMenuItem(title: title, action: #selector(selectSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = radius
            submenu.addItem(item)
            return item
        }

        parent.submenu = submenu
        return parent
    }

    private func makeDarknessMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: localized("menu.dimming", fallback: "Oscuridad"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: localized("menu.dimming", fallback: "Oscuridad"))

        let values: [(String, Int)] = [
            (localized("dimming.soft", fallback: "Suave · 55%"), 55),
            (localized("dimming.medium", fallback: "Media · 75%"), 75),
            (localized("dimming.high", fallback: "Alta · 88%"), 88)
        ]

        darknessItems = values.map { title, percent in
            let item = NSMenuItem(title: title, action: #selector(selectDarkness(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            submenu.addItem(item)
            return item
        }

        parent.submenu = submenu
        return parent
    }

    private func makeDisplayMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: localized("menu.displays", fallback: "Pantallas"), action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: localized("menu.displays", fallback: "Pantallas"))

        currentDisplayItem = NSMenuItem(
            title: localized("displays.current", fallback: "Solo pantalla del cursor"),
            action: #selector(selectCurrentDisplay(_:)),
            keyEquivalent: ""
        )
        currentDisplayItem.target = self
        submenu.addItem(currentDisplayItem)

        allDisplaysItem = NSMenuItem(
            title: localized("displays.all", fallback: "Oscurecer todas"),
            action: #selector(selectAllDisplays(_:)),
            keyEquivalent: ""
        )
        allDisplaysItem.target = self
        submenu.addItem(allDisplaysItem)

        parent.submenu = submenu
        return parent
    }

    @objc private func toggleMagnifierFromMenu(_ sender: Any?) {
        if activeTool == .magnifier {
            deactivateMagnifier(reason: "menu")
        } else {
            activateMagnifier(reason: "menu")
        }
    }

    @objc private func toggleAreaFromMenu(_ sender: Any?) {
        if activeTool == .area {
            deactivateArea(reason: "menu")
        } else {
            activateAreaSelection(reason: "menu")
        }
    }

    @objc private func selectZoomLevel(_ sender: NSMenuItem) {
        if activeTool == .area {
            setAreaLevel(AreaLevel.at(index: sender.tag), source: "menu")
        } else {
            setZoomLevel(
                ZoomLevel.at(index: sender.tag),
                source: "menu",
                showHUD: activeTool == .magnifier
            )
        }
    }

    @objc private func selectHoldMode(_ sender: Any?) {
        activationMode = .hold
    }

    @objc private func selectToggleMode(_ sender: Any?) {
        activationMode = .toggle
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        circleRadius = CGFloat(sender.tag)
    }

    @objc private func selectDarkness(_ sender: NSMenuItem) {
        dimAlpha = CGFloat(sender.tag) / 100.0
    }

    @objc private func selectCurrentDisplay(_ sender: Any?) {
        displayScope = .current
    }

    @objc private func selectAllDisplays(_ sender: Any?) {
        displayScope = .all
    }

    private func showOnboardingIfNeeded() {
        guard !preferences.hasCompletedOnboarding else { return }
        guard onboardingWindowController == nil else { return }

        let controller = OnboardingWindowController(
            isScreenCaptureGranted: { [weak self] in
                self?.screenPermission.isGranted ?? false
            },
            requestScreenCaptureAccess: { [weak self] in
                self?.ensureScreenCaptureAccessForActivation() ?? false
            },
            openScreenCaptureSettings: { [weak self] in
                self?.openScreenCaptureSettings()
            },
            onComplete: { [weak self] in
                self?.preferences.hasCompletedOnboarding = true
            }
        )
        onboardingWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettings(_ sender: Any?) {
        deactivateActiveTool(reason: "open settings")
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(preferences: preferences)
        }
        settingsWindowController?.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApplication(_ sender: Any?) {
        deactivateActiveTool(reason: "quit")
        NSApplication.shared.terminate(sender)
    }

    private func updateMenuState() {
        guard statusItem != nil else { return }

        toggleMenuItem?.title = activeTool == .magnifier
            ? localized("magnifier.disable", fallback: "Desactivar lupa")
            : localized("magnifier.enable", fallback: "Activar lupa")
        areaMenuItem?.title = activeTool == .area
            ? localized("area.disable", fallback: "Desactivar área")
            : localized("area.enable", fallback: "Seleccionar área")
        toggleMenuItem?.state = activeTool == .magnifier ? .on : .off
        areaMenuItem?.state = activeTool == .area ? .on : .off

        let permissionGranted = CGPreflightScreenCaptureAccess()
        screenPermissionMenuItem?.title = captureFailedForSession
            ? localized("menu.permission.captureReview", fallback: "Revisar captura de Lupa/Área y permiso…")
            : (permissionGranted
                ? localized("menu.permission.granted", fallback: "Lupa/Área x2/x3: permiso de pantalla concedido")
                : localized("menu.permission", fallback: "Revisar permiso de pantalla para Lupa/Área…"))

        holdModeItem?.state = activationMode == .hold ? .on : .off
        toggleModeItem?.state = activationMode == .toggle ? .on : .off
        currentDisplayItem?.state = displayScope == .current ? .on : .off
        allDisplaysItem?.state = displayScope == .all ? .on : .off

        for item in zoomItems {
            if activeTool == .area {
                let level = AreaLevel.at(index: item.tag)
                item.title = areaMenuTitle(for: level)
                item.state = item.tag == areaLevel.index ? .on : .off
                item.isEnabled = selectedAreaOverlay() != nil
            } else {
                let level = ZoomLevel.at(index: item.tag)
                item.title = level.menuTitle
                item.state = item.tag == zoomLevel.index ? .on : .off
                item.isEnabled = true
            }
        }

        for item in sizeItems {
            item.state = abs(CGFloat(item.tag) - circleRadius) < 0.5 ? .on : .off
        }

        for item in darknessItems {
            let selectedPercent = Int(round(dimAlpha * 100))
            item.state = item.tag == selectedPercent ? .on : .off
        }

        setStatusIcon(tool: activeTool)
    }

    private func setStatusIcon(tool: HAZTool?) {
        guard let button = statusItem?.button else { return }

        let imageName: String
        let fallbackSymbol: String
        let toolTip: String

        switch tool {
        case .magnifier:
            imageName = "HAZ-magnifier"
            fallbackSymbol = "◎"
            toolTip = localized("status.active", fallback: "HAZ · lupa activa · ⌃⌥F")
        case .area:
            imageName = "HAZ-active"
            fallbackSymbol = "●"
            switch areaLevel {
            case .x1:
                toolTip = localized("status.area", fallback: "HAZ · área activa · ⌃⌥A")
            case .x2:
                toolTip = localized("status.area.x2", fallback: "HAZ · Área x2 · ⌃⌥2")
            case .x3:
                toolTip = localized("status.area.x3", fallback: "HAZ · Área x3 · ⌃⌥3")
            }
        case nil:
            imageName = "HAZ-inactive"
            fallbackSymbol = "○"
            toolTip = localized("status.inactive", fallback: "HAZ · lista · ⌃⌥F / ⌃⌥A")
        }

        if let image = NSImage(named: NSImage.Name(imageName)) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = fallbackSymbol
        }

        button.toolTip = toolTip
    }

    #if DEBUG
    /// Prueba local desde el mismo paquete firmado que ejecuta Xcode.
    private func runCaptureDiagnosticIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--request-screen-permission") {
            _ = ensureScreenCaptureAccessForActivation()
            logScreenCaptureState(prefix: "después de solicitar")
            return
        }
        if arguments.contains("--diagnose-controls") {
            Task { await runControlDiagnostics() }
            return
        }
        guard arguments.contains("--diagnose-capture") else { return }
        guard screenPermission.isGranted else {
            print("[HAZ] DIAGNÓSTICO: permiso pendiente; no se inicia ScreenCaptureKit")
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        activateMagnifier(reason: "diagnóstico local")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            let frame = self.magnifierCapture.latestFrame()
            print("[HAZ] DIAGNÓSTICO: fotogramas=\(frame?.sequence ?? 0), imagen=\(frame?.image.width ?? 0)x\(frame?.image.height ?? 0)")
            self.deactivateMagnifier(reason: "fin del diagnóstico")
            NSApp.terminate(nil)
        }
    }
    /// Recorre los controles con la captura real. Restaura las preferencias al terminar.
    private func runControlDiagnostics() async {
        guard screenPermission.isGranted else {
            print("[HAZ] PRUEBAS: permiso pendiente")
            NSApp.terminate(nil)
            return
        }
        let previousMode = activationMode
        let previousZoom = zoomLevel
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("[HAZ] PRUEBA \(condition ? "OK" : "FALLO"): \(message)")
            if !condition { failures += 1 }
        }
        func waitForFrame(displayID: CGDirectDisplayID? = nil) async -> Bool {
            for _ in 0..<40 {
                if let frame = magnifierCapture.latestFrame(),
                   displayID == nil || frame.displayID == displayID { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }

        activationMode = .hold
        hotKeys.onMagnifierPressed?()
        // Los callbacks del atajo pasan por la cola principal, como en uso normal.
        try? await Task.sleep(for: .milliseconds(100))
        check(isActive, "Mantener activa al pulsar")
        check(await waitForFrame(), "Mantener recibe imágenes reales")
        check(overlays.allSatisfy { $0.window.ignoresMouseEvents }, "Mantener permite clics hacia otras aplicaciones")
        hotKeys.onMagnifierReleased?()
        try? await Task.sleep(for: .milliseconds(100))
        check(!isActive && magnifierCapture.latestFrame() == nil, "Soltar detiene captura y descarta imagen")
        check(overlays.allSatisfy { !$0.window.isVisible }, "Soltar oculta todas las ventanas")

        activationMode = .toggle
        hotKeys.onMagnifierPressed?()
        try? await Task.sleep(for: .milliseconds(100))
        hotKeys.onMagnifierReleased?()
        try? await Task.sleep(for: .milliseconds(100))
        check(isActive, "Alternar sigue activo después de soltar")
        check(await waitForFrame(), "Alternar reinicia captura correctamente")
        check(overlays.allSatisfy { $0.window.ignoresMouseEvents }, "Alternar permite clics hacia otras aplicaciones")
        let motion = MagnifierZoomTransition(from: 1.0, to: 2.0, start: 0, duration: 0.18)
        let midpoint = motion.value(at: 0.09)
        check(motion.value(at: 0) == 1.0 && midpoint > 1.0 && midpoint < 2.0
              && motion.value(at: 0.18) == 2.0, "Zoom motion: endpoints and bounded interpolation")
        let reverse = MagnifierZoomTransition(from: midpoint, to: 1.25, start: 0.09, duration: 0.12)
        check(reverse.value(at: 0.09) == midpoint && reverse.value(at: 0.22) == 1.25,
              "Zoom motion: reversal continues from current scale")
        let expectedScales: [CGFloat] = [1.25, 1.60, 2.00]
        for (index, scale) in expectedScales.enumerated() {
            hotKeys.onZoomLevelSelected?(index + 1)
            try? await Task.sleep(for: .milliseconds(350))
            check(zoomLevel.magnification == scale && overlays.allSatisfy { $0.view.magnification == scale },
                  "Zoom x\(index + 1) = \(scale)")
        }
        hotKeys.onMagnifierPressed?()
        try? await Task.sleep(for: .milliseconds(100))
        hotKeys.onMagnifierReleased?()
        try? await Task.sleep(for: .milliseconds(100))
        check(!isActive, "Segunda pulsación desactiva Alternar")

        hotKeys.onMagnifierPressed?()
        try? await Task.sleep(for: .milliseconds(100))
        hotKeys.onMagnifierReleased?()
        check(await waitForFrame(), "Nueva activación recibe imágenes")
        hotKeys.onEscapePressed?()
        try? await Task.sleep(for: .milliseconds(100))
        check(!isActive && overlays.allSatisfy { !$0.window.isVisible }, "Escape apaga y oculta la lupa")
        check(magnifierCapture.latestFrame() == nil, "Escape descarta el fotograma capturado")

        // Comprobar cada pantalla disponible sin mover el cursor del usuario.
        for screen in NSScreen.screens {
            guard let displayID = MagnifierCaptureManager.displayID(for: screen) else { continue }
            magnifierCapture.start(for: screen)
            check(await waitForFrame(displayID: displayID), "Captura de \(screen.localizedName), pantalla=\(displayID)")
        }
        if NSScreen.screens.count < 2 {
            print("[HAZ] PRUEBA PENDIENTE: cambio real entre monitores; solo hay uno conectado")
        }
        stopMagnifierCapture()
        try? await Task.sleep(for: .milliseconds(300))
        check(magnifierCapture.latestFrame() == nil, "No llegan imágenes tardías tras detener")
        check(!screenPermission.didRequest, "No se solicita permiso durante toda la prueba")
        check(screenPermission.isGranted, "El permiso continúa concedido")
        hotKeyIsPhysicallyDown = false
        activationMode = previousMode
        zoomLevel = previousZoom
        print("[HAZ] PRUEBAS TERMINADAS: fallos=\(failures)")
        NSApp.terminate(nil)
    }
    #endif

    // MARK: - Lifecycle

    func applicationWillTerminate(_ notification: Notification) {
        zoomHUDWorkItem?.cancel()
        areaHUDWorkItem?.cancel()
        stopCursorTracking()
        stopAreaCaptureTracking()
        destroyAreaInteractionWindows()
        stopMagnifierCapture()
        hotKeys.unregisterEscape()
        NotificationCenter.default.removeObserver(self)
        overlays.forEach { $0.window.close() }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func formatMS(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func formatZoom(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }
}
