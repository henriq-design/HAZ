import Cocoa

private let hazMagnifierBlue = NSColor(
    srgbRed: 53.0 / 255.0,
    green: 109.0 / 255.0,
    blue: 1.0,
    alpha: 1.0
)

/// Medium interpolation keeps UI text and 1 px strokes crisper when the
/// Retina capture is enlarged. Set HAZ_IMAGE_INTERPOLATION=high for an A/B
/// comparison without changing the product setting.
private let hazImageInterpolation: NSImageInterpolation = {
    switch ProcessInfo.processInfo.environment["HAZ_IMAGE_INTERPOLATION"]?.lowercased() {
    case "high": return .high
    case "low": return .low
    case "none": return .none
    default: return .medium
    }
}()

final class FlashlightView: NSView {

    /// Tool rendered by this overlay. A nil tool keeps the prepared overlay
    /// completely passive and invisible.
    var activeTool: HAZTool? {
        didSet {
            needsDisplay = true
            invalidateToolCursor()
        }
    }

    /// Magnifier center in this view's coordinate system. `nil` means the
    /// display stays dimmed without a lens (used on secondary screens).
    var circleCenter: CGPoint? {
        didSet { needsDisplay = true }
    }

    /// Radius of the magnifier lens.
    var circleRadius: CGFloat = 140.0 {
        didSet { needsDisplay = true }
    }

    /// Darkness outside the active focus region, from 0 (transparent) to 1 (black).
    var dimAlpha: CGFloat = 0.75 {
        didSet { needsDisplay = true }
    }

    /// Tuned optical scale. Product levels x1/x2/x3 currently map to
    /// 1.25x / 1.60x / 2.00x respectively.
    var magnification: CGFloat = 1.25 {
        didSet { needsDisplay = true }
    }

    /// Latest ScreenCaptureKit frame for this display. The view does not own a
    /// capture session; it only renders the most recent image it receives.
    var capturedFrame: CGImage? {
        didSet { needsDisplay = true }
    }

    /// Temporary feedback shown after changing zoom.
    var zoomHUDText: String? {
        didSet { needsDisplay = true }
    }

    /// Current area selection. It is local to this screen/view.
    var areaSelectionRect: CGRect? {
        didSet { needsDisplay = true }
    }

    /// Area stays 1:1 at x1. x2/x3 render the live captured screen inside
    /// the same selection without changing its physical bounds.
    var areaMagnification: CGFloat = 1.0 {
        didSet { needsDisplay = true }
    }

    /// Brief feedback shown after changing the Area level.
    var areaHUDText: String? {
        didSet { needsDisplay = true }
    }

    /// Guide coordinates are local to the selected Area.
    var areaHorizontalGuideY: CGFloat? {
        didSet { needsDisplay = true }
    }

    var areaVerticalGuideX: CGFloat? {
        didSet { needsDisplay = true }
    }

    var areaHoveredGuideAxis: AreaGuideAxis? {
        didSet { needsDisplay = true }
    }

    var areaDraggingGuideAxis: AreaGuideAxis? {
        didSet { needsDisplay = true }
    }

    /// While armed, the overlay receives the drag gesture. After a valid
    /// selection completes, AppDelegate makes the window click-through again.
    var isAreaSelectionArmed = false {
        didSet {
            needsDisplay = true
            invalidateToolCursor()
        }
    }

    var onAreaSelectionCompleted: ((CGRect) -> Void)?

    private var areaDragStart: CGPoint?

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        activeTool == .area && isAreaSelectionArmed
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        switch activeTool {
        case .magnifier:
            drawMagnifier()
        case .area:
            drawArea()
        case nil:
            break
        }
    }

    // MARK: - Magnifier

    private func drawMagnifier() {
        drawMagnifierDimmingMask(center: circleCenter, alpha: dimAlpha)

        guard let circleCenter else { return }

        if let capturedFrame {
            drawMagnifiedFrame(
                capturedFrame,
                centeredAt: circleCenter,
                zoom: magnification
            )

            let workspace = NSWorkspace.shared
            if MagnifierOptics.shouldRenderRefraction(
                reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency
            ) {
                drawRefractedEdge(
                    capturedFrame,
                    centeredAt: circleCenter,
                    zoom: magnification
                )
            }
        }

        // Optical Edge is rendered independently from the captured content so
        // the center of the lens remains untouched and fully sharp.
        drawOpticalRim(centeredAt: circleCenter)

        if let zoomHUDText {
            drawZoomHUD(zoomHUDText, centeredAt: circleCenter)
        }
    }

    private func drawMagnifiedFrame(
        _ frame: CGImage,
        centeredAt center: CGPoint,
        zoom: CGFloat
    ) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let lensPath = NSBezierPath(ovalIn: lensRect(centeredAt: center))
        lensPath.addClip()

        // Give the captured frame the same logical size as the display. This
        // makes the transform independent of Retina pixel density.
        let image = NSImage(cgImage: frame, size: bounds.size)

        // Scale the whole captured display around the cursor. The source point
        // directly beneath the cursor remains fixed at the lens center:
        // origin + zoom * center == center.
        let destination = magnifiedDestination(
            centeredAt: center,
            zoom: zoom
        )

        NSGraphicsContext.current?.imageInterpolation = hazImageInterpolation
        image.draw(
            in: destination,
            from: NSRect(origin: .zero, size: bounds.size),
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )
    }

    private func drawRefractedEdge(
        _ frame: CGImage,
        centeredAt center: CGPoint,
        zoom: CGFloat
    ) {
        let outerRect = lensRect(centeredAt: center).insetBy(dx: 0.5, dy: 0.5)
        let bandCount = max(MagnifierOptics.refractionBandCount, 1)
        let bandWidth = MagnifierOptics.edgeWidth / CGFloat(bandCount)
        let image = NSImage(cgImage: frame, size: bounds.size)

        // Split the optical edge into narrow concentric rings. Each ring uses
        // slightly less radial displacement toward the lens interior, which
        // softens the transition while preserving crisp source pixels.
        for band in 0..<bandCount {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }

            let outerInset = CGFloat(band) * bandWidth
            let innerInset = min(
                CGFloat(band + 1) * bandWidth,
                MagnifierOptics.edgeWidth
            )

            let bandOuterRect = outerRect.insetBy(
                dx: outerInset,
                dy: outerInset
            )
            let bandInnerRect = outerRect.insetBy(
                dx: innerInset,
                dy: innerInset
            )

            let annulus = NSBezierPath()
            annulus.appendOval(in: bandOuterRect)
            annulus.appendOval(in: bandInnerRect)
            annulus.windingRule = .evenOdd
            annulus.addClip()

            let refractedZoom = MagnifierOptics.refractedZoom(
                from: zoom,
                band: band
            )
            let destination = magnifiedDestination(
                centeredAt: center,
                zoom: refractedZoom
            )

            NSGraphicsContext.current?.imageInterpolation = hazImageInterpolation
            image.draw(
                in: destination,
                from: NSRect(origin: .zero, size: bounds.size),
                operation: .copy,
                fraction: 1.0,
                respectFlipped: true,
                hints: nil
            )
        }
    }

    private func drawOpticalRim(centeredAt center: CGPoint) {
        let workspace = NSWorkspace.shared
        let increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        let reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency

        let lens = lensRect(centeredAt: center)
        let outer = NSBezierPath(
            ovalIn: lens.insetBy(dx: 0.55, dy: 0.55)
        )
        outer.lineWidth = increaseContrast ? 1.25 : 1.0

        let outerAlpha = reduceTransparency
            ? max(MagnifierOptics.outerLightAlpha(increaseContrast: increaseContrast), 0.58)
            : MagnifierOptics.outerLightAlpha(increaseContrast: increaseContrast)
        NSColor.white.withAlphaComponent(outerAlpha).setStroke()
        outer.stroke()

        let inner = NSBezierPath(
            ovalIn: lens.insetBy(dx: 2.0, dy: 2.0)
        )
        inner.lineWidth = increaseContrast ? 1.0 : 0.75
        NSColor.black.withAlphaComponent(
            MagnifierOptics.innerDarkAlpha(increaseContrast: increaseContrast)
        ).setStroke()
        inner.stroke()

        // One restrained specular arc is enough to suggest curved glass. It is
        // geometry-only: no blur, glow or animation over the focused content.
        let highlight = NSBezierPath()
        highlight.appendArc(
            withCenter: center,
            radius: max(circleRadius - 1.4, 1),
            startAngle: 58,
            endAngle: 154,
            clockwise: false
        )
        highlight.lineWidth = increaseContrast ? 1.45 : 1.15
        NSColor.white.withAlphaComponent(
            MagnifierOptics.highlightAlpha(increaseContrast: increaseContrast)
        ).setStroke()
        highlight.stroke()
    }

    private func drawZoomHUD(_ text: String, centeredAt center: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]

        let textSize = text.size(withAttributes: attributes)
        let horizontalPadding: CGFloat = 10
        let verticalPadding: CGFloat = 5
        let pillSize = NSSize(
            width: textSize.width + (horizontalPadding * 2),
            height: textSize.height + (verticalPadding * 2)
        )

        // Keep the indicator inside the lens without covering the cursor.
        let pillRect = NSRect(
            x: center.x - pillSize.width / 2,
            y: center.y - circleRadius + 18,
            width: pillSize.width,
            height: pillSize.height
        )

        let pill = NSBezierPath(
            roundedRect: pillRect,
            xRadius: pillRect.height / 2,
            yRadius: pillRect.height / 2
        )
        hazMagnifierBlue.withAlphaComponent(0.92).setFill()
        pill.fill()

        let textPoint = NSPoint(
            x: pillRect.midX - textSize.width / 2,
            y: pillRect.midY - textSize.height / 2
        )
        text.draw(at: textPoint, withAttributes: attributes)
    }

    private func magnifiedDestination(
        centeredAt center: CGPoint,
        zoom: CGFloat
    ) -> NSRect {
        NSRect(
            x: center.x - (center.x * zoom),
            y: center.y - (center.y * zoom),
            width: bounds.width * zoom,
            height: bounds.height * zoom
        )
    }

    private func lensRect(centeredAt center: CGPoint) -> NSRect {
        NSRect(
            x: center.x - circleRadius,
            y: center.y - circleRadius,
            width: circleRadius * 2,
            height: circleRadius * 2
        )
    }

    // MARK: - Area

    private func drawArea() {
        let validSelection = areaSelectionRect.flatMap {
            AreaSelectionGeometry.isMeaningful($0) ? $0 : nil
        }

        // Keep the screen readable while the user is deciding what to select.
        // Once the drag completes, use the configured product dimming level.
        let maskAlpha = isAreaSelectionArmed ? min(dimAlpha, 0.22) : dimAlpha
        drawAreaDimmingMask(cutout: validSelection, alpha: maskAlpha)

        guard let rect = areaSelectionRect, rect.width > 0, rect.height > 0 else { return }

        if areaMagnification > 1.0, let capturedFrame {
            drawAreaMagnifiedFrame(
                capturedFrame,
                in: rect,
                zoom: areaMagnification
            )
        }

        let border = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.75, dy: 0.75),
            xRadius: 8,
            yRadius: 8
        )
        border.lineWidth = 1.5
        hazMagnifierBlue.withAlphaComponent(0.96).setStroke()
        border.stroke()

        if !isAreaSelectionArmed {
            drawAreaGuideOrigins(in: rect)
            drawAreaGuides(in: rect)
        }

        if let areaHUDText {
            drawAreaHUD(areaHUDText, in: rect)
        }
    }

    private func drawAreaMagnifiedFrame(
        _ frame: CGImage,
        in rect: CGRect,
        zoom: CGFloat
    ) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let clip = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        clip.addClip()

        // ScreenCaptureKit provides the full display. Give it the logical
        // screen size so Retina pixels remain 1:1 with AppKit points before
        // applying the Area scale around the selected region's center.
        let image = NSImage(cgImage: frame, size: bounds.size)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let destination = NSRect(
            x: center.x - (center.x * zoom),
            y: center.y - (center.y * zoom),
            width: bounds.width * zoom,
            height: bounds.height * zoom
        )

        NSGraphicsContext.current?.imageInterpolation = hazImageInterpolation
        image.draw(
            in: destination,
            from: NSRect(origin: .zero, size: bounds.size),
            operation: .copy,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )
    }

    private func drawAreaGuideOrigins(in rect: CGRect) {
        func opacity(for axis: AreaGuideAxis) -> CGFloat {
            if areaDraggingGuideAxis == axis || areaHoveredGuideAxis == axis {
                return 1.0
            }
            return 0.70
        }

        // Source rails are slightly stronger than placed guides, but remain
        // visually subordinate to the content. They disappear once a guide of
        // that orientation exists.
        if areaHorizontalGuideY == nil {
            let y = rect.maxY - 2.5
            let rail = NSBezierPath()
            rail.move(to: NSPoint(x: rect.minX + 8, y: y))
            rail.line(to: NSPoint(x: rect.maxX - 8, y: y))
            rail.lineWidth = 2.0
            hazMagnifierBlue.withAlphaComponent(opacity(for: .horizontal)).setStroke()
            rail.stroke()
        }

        if areaVerticalGuideX == nil {
            let x = rect.minX + 2.5
            let rail = NSBezierPath()
            rail.move(to: NSPoint(x: x, y: rect.minY + 8))
            rail.line(to: NSPoint(x: x, y: rect.maxY - 8))
            rail.lineWidth = 2.0
            hazMagnifierBlue.withAlphaComponent(opacity(for: .vertical)).setStroke()
            rail.stroke()
        }
    }

    private func drawAreaGuides(in rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let clip = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        clip.addClip()

        func opacity(for axis: AreaGuideAxis) -> CGFloat {
            if areaDraggingGuideAxis == axis { return 1.0 }
            if areaHoveredGuideAxis == axis { return 0.80 }
            return 0.60
        }

        if let localY = areaHorizontalGuideY {
            let y = rect.minY + min(max(localY, 0), rect.height)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.minX, y: y))
            line.line(to: NSPoint(x: rect.maxX, y: y))
            line.lineWidth = 1.0
            hazMagnifierBlue.withAlphaComponent(opacity(for: .horizontal)).setStroke()
            line.stroke()
        }

        if let localX = areaVerticalGuideX {
            let x = rect.minX + min(max(localX, 0), rect.width)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: rect.minY))
            line.line(to: NSPoint(x: x, y: rect.maxY))
            line.lineWidth = 1.0
            hazMagnifierBlue.withAlphaComponent(opacity(for: .vertical)).setStroke()
            line.stroke()
        }
    }

    private func drawAreaHUD(_ text: String, in rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]

        let textSize = text.size(withAttributes: attributes)
        let horizontalPadding: CGFloat = 10
        let verticalPadding: CGFloat = 5
        let pillSize = NSSize(
            width: textSize.width + (horizontalPadding * 2),
            height: textSize.height + (verticalPadding * 2)
        )

        let pillRect = NSRect(
            x: rect.midX - pillSize.width / 2,
            y: rect.minY + 12,
            width: pillSize.width,
            height: pillSize.height
        )

        let pill = NSBezierPath(
            roundedRect: pillRect,
            xRadius: pillRect.height / 2,
            yRadius: pillRect.height / 2
        )
        hazMagnifierBlue.withAlphaComponent(0.92).setFill()
        pill.fill()

        let textPoint = NSPoint(
            x: pillRect.midX - textSize.width / 2,
            y: pillRect.midY - textSize.height / 2
        )
        text.draw(at: textPoint, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        guard activeTool == .area, isAreaSelectionArmed else {
            super.mouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        areaDragStart = point
        areaSelectionRect = CGRect(origin: point, size: .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeTool == .area,
              isAreaSelectionArmed,
              let start = areaDragStart else {
            super.mouseDragged(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        areaSelectionRect = AreaSelectionGeometry.rect(from: start, to: point)
    }

    override func mouseUp(with event: NSEvent) {
        guard activeTool == .area,
              isAreaSelectionArmed,
              let start = areaDragStart else {
            super.mouseUp(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let rect = AreaSelectionGeometry.rect(from: start, to: point)
        areaDragStart = nil

        guard AreaSelectionGeometry.isMeaningful(rect) else {
            areaSelectionRect = nil
            return
        }

        areaSelectionRect = rect
        isAreaSelectionArmed = false
        onAreaSelectionCompleted?(rect)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if activeTool == .area, isAreaSelectionArmed {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    private func invalidateToolCursor() {
        guard let window else { return }
        window.invalidateCursorRects(for: self)
    }

    // MARK: - Shared overlay

    private func drawMagnifierDimmingMask(center: CGPoint?, alpha: CGFloat) {
        let dimmedArea = NSBezierPath(rect: bounds)

        if let center {
            // Magnifier must cut an actual circular hole. Reusing Area's
            // rounded-rectangle cutout produced a visible square behind the lens.
            dimmedArea.appendOval(in: lensRect(centeredAt: center))
        }

        fillDimmingMask(dimmedArea, alpha: alpha)
    }

    private func drawAreaDimmingMask(cutout: CGRect?, alpha: CGFloat) {
        let dimmedArea = NSBezierPath(rect: bounds)

        if let cutout {
            dimmedArea.append(NSBezierPath(roundedRect: cutout, xRadius: 8, yRadius: 8))
        }

        fillDimmingMask(dimmedArea, alpha: alpha)
    }

    private func fillDimmingMask(_ path: NSBezierPath, alpha: CGFloat) {
        // Even-odd fill turns the appended focus region into a transparent hole.
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(alpha).setFill()
        path.fill()
    }
}
