import CoreGraphics

enum AreaGuideAxis: String, Equatable {
    case horizontal
    case vertical
}

enum AreaGuideGeometry {
    static let sourceInset: CGFloat = 8
    static let hitTolerance: CGFloat = 5
    static let removalInset: CGFloat = 8

    static func preferredAxis(
        at point: CGPoint,
        in bounds: CGRect,
        horizontalGuideY: CGFloat?,
        verticalGuideX: CGFloat?
    ) -> AreaGuideAxis? {
        let horizontalDistance = horizontalGuideY.map { abs(point.y - $0) }
        let verticalDistance = verticalGuideX.map { abs(point.x - $0) }

        let horizontalHit = horizontalDistance.map { $0 <= hitTolerance } ?? false
        let verticalHit = verticalDistance.map { $0 <= hitTolerance } ?? false

        if horizontalHit || verticalHit {
            switch (horizontalHit, verticalHit) {
            case (true, true):
                return (horizontalDistance ?? .greatestFiniteMagnitude)
                    <= (verticalDistance ?? .greatestFiniteMagnitude)
                    ? .horizontal
                    : .vertical
            case (true, false):
                return .horizontal
            case (false, true):
                return .vertical
            case (false, false):
                break
            }
        }

        let topDistance = abs(bounds.maxY - point.y)
        let leftDistance = abs(point.x - bounds.minX)
        let topHit = topDistance <= sourceInset
        let leftHit = leftDistance <= sourceInset

        switch (topHit, leftHit) {
        case (true, true):
            return topDistance <= leftDistance ? .horizontal : .vertical
        case (true, false):
            return .horizontal
        case (false, true):
            return .vertical
        case (false, false):
            return nil
        }
    }

    static func clampedPosition(
        for axis: AreaGuideAxis,
        point: CGPoint,
        in bounds: CGRect
    ) -> CGFloat {
        switch axis {
        case .horizontal:
            return min(max(point.y, bounds.minY), bounds.maxY)
        case .vertical:
            return min(max(point.x, bounds.minX), bounds.maxX)
        }
    }

    static func shouldRemove(
        axis: AreaGuideAxis,
        position: CGFloat,
        in bounds: CGRect
    ) -> Bool {
        switch axis {
        case .horizontal:
            return position >= bounds.maxY - removalInset
        case .vertical:
            return position <= bounds.minX + removalInset
        }
    }
}
