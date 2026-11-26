import CoreGraphics

enum AreaSelectionGeometry {
    static let minimumSide: CGFloat = 8

    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    static func isMeaningful(_ rect: CGRect) -> Bool {
        rect.width >= minimumSide && rect.height >= minimumSide
    }
}
