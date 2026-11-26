import CoreGraphics

enum CaptureGeometry {
    struct PixelSize: Equatable {
        let width: Int
        let height: Int
    }

    /// Converts ScreenCaptureKit dimensions expressed in screen points into
    /// output pixels. A scale below 1 is treated as 1 to avoid accidental
    /// downsampling.
    static func pixelSize(
        contentSizeInPoints: CGSize,
        pointPixelScale: CGFloat
    ) -> PixelSize {
        let scale = max(pointPixelScale, 1.0)
        return PixelSize(
            width: max(Int((contentSizeInPoints.width * scale).rounded()), 1),
            height: max(Int((contentSizeInPoints.height * scale).rounded()), 1)
        )
    }
}
