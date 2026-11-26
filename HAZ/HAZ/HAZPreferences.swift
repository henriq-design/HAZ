import Foundation
import CoreGraphics

/// Single source of truth for user-configurable HAZ behavior.
///
/// Keep the existing UserDefaults keys stable so v0.6.0 does not migrate or
/// reset preferences from earlier versions. UI surfaces should mutate this
/// model instead of writing to UserDefaults directly.
@MainActor
final class HAZPreferences {
    enum ActivationMode: String {
        case hold
        case toggle
    }

    enum DisplayScope: String {
        case current
        case all
    }

    /// Product zoom levels. Labels remain x1/x2/x3 while the optical scale is
    /// tuned for readability and capped to avoid unnecessary pixelation.
    enum ZoomLevel: String, CaseIterable {
        case x1
        case x2
        case x3

        var magnification: CGFloat {
            switch self {
            case .x1: return 1.25
            case .x2: return 1.60
            case .x3: return 2.00
            }
        }

        var menuTitle: String {
            switch self {
            case .x1:
                return NSLocalizedString(
                    "zoom.x1",
                    tableName: "Localizable",
                    bundle: .main,
                    value: "Lupa x1 · Suave",
                    comment: ""
                )
            case .x2:
                return NSLocalizedString(
                    "zoom.x2",
                    tableName: "Localizable",
                    bundle: .main,
                    value: "Lupa x2 · Medio",
                    comment: ""
                )
            case .x3:
                return NSLocalizedString(
                    "zoom.x3",
                    tableName: "Localizable",
                    bundle: .main,
                    value: "Lupa x3 · Máximo",
                    comment: ""
                )
            }
        }

        var hudTitle: String {
            switch self {
            case .x1: return "x1"
            case .x2: return "x2"
            case .x3: return "x3"
            }
        }

        var index: Int {
            switch self {
            case .x1: return 0
            case .x2: return 1
            case .x3: return 2
            }
        }

        static func at(index: Int) -> ZoomLevel {
            let values = allCases
            return values[min(max(index, 0), values.count - 1)]
        }
    }

    enum Change {
        case activationMode
        case displayScope
        case circleRadius
        case dimAlpha
        case zoomLevel
    }

    private enum Key {
        static let activationMode = "activationMode"
        static let radius = "circleRadius"
        static let dimAlpha = "dimAlpha"
        static let displayScope = "displayScope"
        static let zoomLevel = "zoomLevel"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let legacyFocusMode = "focusMode"
    }

    private let defaults: UserDefaults
    private var observers: [UUID: (Change) -> Void] = [:]

    @discardableResult
    func observe(_ observer: @escaping (Change) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    private func publish(_ change: Change) {
        for observer in Array(observers.values) {
            observer(change)
        }
    }

    var activationMode: ActivationMode {
        didSet {
            guard activationMode != oldValue else { return }
            defaults.set(activationMode.rawValue, forKey: Key.activationMode)
            publish(.activationMode)
        }
    }

    var displayScope: DisplayScope {
        didSet {
            guard displayScope != oldValue else { return }
            defaults.set(displayScope.rawValue, forKey: Key.displayScope)
            publish(.displayScope)
        }
    }

    var circleRadius: CGFloat {
        didSet {
            guard circleRadius != oldValue else { return }
            defaults.set(Double(circleRadius), forKey: Key.radius)
            publish(.circleRadius)
        }
    }

    var dimAlpha: CGFloat {
        didSet {
            guard dimAlpha != oldValue else { return }
            defaults.set(Double(dimAlpha), forKey: Key.dimAlpha)
            publish(.dimAlpha)
        }
    }

    var zoomLevel: ZoomLevel {
        didSet {
            guard zoomLevel != oldValue else { return }
            defaults.set(zoomLevel.rawValue, forKey: Key.zoomLevel)
            publish(.zoomLevel)
        }
    }

    var hasCompletedOnboarding: Bool {
        didSet {
            guard hasCompletedOnboarding != oldValue else { return }
            defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let rawMode = defaults.string(forKey: Key.activationMode),
           let storedMode = ActivationMode(rawValue: rawMode) {
            activationMode = storedMode
        } else {
            activationMode = .hold
        }

        if let rawScope = defaults.string(forKey: Key.displayScope),
           let storedScope = DisplayScope(rawValue: rawScope) {
            displayScope = storedScope
        } else {
            displayScope = .current
        }

        if let rawZoom = defaults.string(forKey: Key.zoomLevel),
           let storedZoom = ZoomLevel(rawValue: rawZoom) {
            zoomLevel = storedZoom
        } else {
            zoomLevel = .x1
            defaults.removeObject(forKey: Key.legacyFocusMode)
        }

        circleRadius = defaults.object(forKey: Key.radius) != nil
            ? CGFloat(defaults.double(forKey: Key.radius))
            : 140

        dimAlpha = defaults.object(forKey: Key.dimAlpha) != nil
            ? CGFloat(defaults.double(forKey: Key.dimAlpha))
            : 0.75

        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
    }
}
