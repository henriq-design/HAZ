import CoreGraphics

enum AreaLevel: Int, CaseIterable, Equatable {
    case x1 = 1
    case x2 = 2
    case x3 = 3

    var magnification: CGFloat {
        switch self {
        case .x1: return 1.0
        case .x2: return 1.60
        case .x3: return 2.00
        }
    }

    var requiresCapture: Bool {
        self != .x1
    }

    var index: Int {
        rawValue - 1
    }

    static func at(index: Int) -> AreaLevel {
        let values = allCases
        return values[min(max(index, 0), values.count - 1)]
    }
}
