import CoreGraphics

enum MagnifierOptics {
    static let edgeWidth: CGFloat = 8.0
    static let refractionStrength: CGFloat = 0.006
    static let refractionBandCount = 4

    static func innerLensRect(for lensRect: CGRect) -> CGRect {
        lensRect.insetBy(dx: edgeWidth, dy: edgeWidth)
    }

    /// Returns a very small radial scale for one ring of the optical edge.
    /// Band 0 is the outermost ring. The smoothstep falloff approaches 1.0
    /// toward the inner edge so there is no hard visual jump into the lens.
    static func refractionScale(forBand index: Int) -> CGFloat {
        let count = max(refractionBandCount, 1)
        let clampedIndex = min(max(index, 0), count - 1)
        let outerProgress = 1.0 - ((CGFloat(clampedIndex) + 0.5) / CGFloat(count))
        let eased = outerProgress * outerProgress * (3.0 - (2.0 * outerProgress))
        return 1.0 + (refractionStrength * eased)
    }

    static func refractedZoom(from zoom: CGFloat, band index: Int) -> CGFloat {
        zoom * refractionScale(forBand: index)
    }

    static func shouldRenderRefraction(reduceTransparency: Bool) -> Bool {
        !reduceTransparency
    }

    static func outerLightAlpha(increaseContrast: Bool) -> CGFloat {
        increaseContrast ? 0.72 : 0.42
    }

    static func innerDarkAlpha(increaseContrast: Bool) -> CGFloat {
        increaseContrast ? 0.32 : 0.16
    }

    static func highlightAlpha(increaseContrast: Bool) -> CGFloat {
        increaseContrast ? 0.82 : 0.56
    }
}
