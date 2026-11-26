import Foundation
import CoreGraphics

@main
struct PermissionRegressionTests {
    @MainActor
    static func main() {
        var requests = 0
        var granted = false
        let permission = ScreenCapturePermission(preflight: { granted }, request: {
            requests += 1
            return false
        })
        for _ in 0..<600 { precondition(!permission.ensureAccess()) }
        precondition(requests == 1, "Un rechazo solo debe generar una petición nativa")
        granted = true
        precondition(permission.ensureAccess(), "Debe reconocer una concesión posterior")
        granted = false
        precondition(!permission.ensureAccess())
        precondition(requests == 1, "Revocar no debe iniciar otra petición en el mismo proceso")

        var allowedRequests = 0
        let allowed = ScreenCapturePermission(preflight: { true }, request: {
            allowedRequests += 1
            return true
        })
        precondition(allowed.ensureAccess() && allowedRequests == 0)
        let stale = ScreenCapturePermission(preflight: { false }, request: { true })
        precondition(!stale.ensureAccess(), "La petición no sustituye la comprobación posterior")

        let retina = CaptureGeometry.pixelSize(
            contentSizeInPoints: CGSize(width: 1728, height: 1117),
            pointPixelScale: 2
        )
        precondition(retina == .init(width: 3456, height: 2234), "Retina 2x debe conservar resolución nativa")

        let standard = CaptureGeometry.pixelSize(
            contentSizeInPoints: CGSize(width: 1920, height: 1080),
            pointPixelScale: 1
        )
        precondition(standard == .init(width: 1920, height: 1080), "Pantalla 1x no debe reescalarse")

        let invalidScale = CaptureGeometry.pixelSize(
            contentSizeInPoints: CGSize(width: 100, height: 50),
            pointPixelScale: 0
        )
        precondition(invalidScale == .init(width: 100, height: 50), "Una escala inválida no debe reducir la captura")

        precondition(HAZTool.magnifier.rawValue == "magnifier")
        precondition(HAZTool.area.rawValue == "area")

        let preferencesSuite = "org.hazapp.HAZ.tests.preferences"
        guard let preferencesDefaults = UserDefaults(suiteName: preferencesSuite) else {
            preconditionFailure("No se pudo crear UserDefaults aislado para HAZPreferences")
        }
        preferencesDefaults.removePersistentDomain(forName: preferencesSuite)

        let preferences = HAZPreferences(defaults: preferencesDefaults)
        precondition(preferences.activationMode == .hold)
        precondition(preferences.displayScope == .current)
        precondition(preferences.circleRadius == 140)
        precondition(preferences.dimAlpha == 0.75)
        precondition(preferences.zoomLevel == .x1)
        precondition(!preferences.hasCompletedOnboarding)

        var preferenceChanges: [HAZPreferences.Change] = []
        var mirroredPreferenceChanges = 0
        let primaryPreferenceObservation = preferences.observe { preferenceChanges.append($0) }
        let mirroredPreferenceObservation = preferences.observe { _ in mirroredPreferenceChanges += 1 }
        preferences.activationMode = .toggle
        preferences.displayScope = .all
        preferences.circleRadius = 200
        preferences.dimAlpha = 0.55
        preferences.zoomLevel = .x3
        preferences.hasCompletedOnboarding = true
        precondition(preferenceChanges.count == 5, "Cada preferencia de comportamiento debe publicar un único cambio")
        precondition(mirroredPreferenceChanges == 5, "Menubar y Settings deben poder observar el mismo modelo")
        preferences.removeObserver(primaryPreferenceObservation)
        preferences.removeObserver(mirroredPreferenceObservation)

        precondition(preferencesDefaults.string(forKey: "activationMode") == "toggle")
        precondition(preferencesDefaults.string(forKey: "displayScope") == "all")
        precondition(preferencesDefaults.double(forKey: "circleRadius") == 200)
        precondition(preferencesDefaults.double(forKey: "dimAlpha") == 0.55)
        precondition(preferencesDefaults.string(forKey: "zoomLevel") == "x3")
        precondition(preferencesDefaults.bool(forKey: "hasCompletedOnboarding"))

        let restoredPreferences = HAZPreferences(defaults: preferencesDefaults)
        precondition(restoredPreferences.activationMode == .toggle)
        precondition(restoredPreferences.displayScope == .all)
        precondition(restoredPreferences.circleRadius == 200)
        precondition(restoredPreferences.dimAlpha == 0.55)
        precondition(restoredPreferences.zoomLevel == .x3)
        precondition(restoredPreferences.hasCompletedOnboarding)
        preferencesDefaults.removePersistentDomain(forName: preferencesSuite)

        precondition(AreaLevel.x1.magnification == 1.0)
        precondition(AreaLevel.x2.magnification == 1.60)
        precondition(AreaLevel.x3.magnification == 2.00)
        precondition(!AreaLevel.x1.requiresCapture, "Area x1 debe seguir siendo 1:1 sin captura")
        precondition(AreaLevel.x2.requiresCapture && AreaLevel.x3.requiresCapture,
                     "Area x2/x3 necesita captura para ampliar la región")
        precondition(AreaLevel.at(index: 0) == .x1)
        precondition(AreaLevel.at(index: 1) == .x2)
        precondition(AreaLevel.at(index: 2) == .x3)

        let opticalLens = CGRect(x: 10, y: 20, width: 280, height: 280)
        let opticalInner = MagnifierOptics.innerLensRect(for: opticalLens)
        precondition(opticalInner == opticalLens.insetBy(dx: 8, dy: 8),
                     "Optical Edge debe limitarse a una banda de 8 pt")

        let outerRefraction = MagnifierOptics.refractionScale(forBand: 0)
        let innerRefraction = MagnifierOptics.refractionScale(
            forBand: MagnifierOptics.refractionBandCount - 1
        )
        precondition(outerRefraction > innerRefraction,
                     "La refracción debe caer suavemente hacia el centro")
        precondition(outerRefraction < 1.006 && innerRefraction < 1.001,
                     "La refracción debe mantenerse extremadamente sutil")
        precondition(
            MagnifierOptics.refractedZoom(from: 2.0, band: 0) < 2.012,
            "Optical Edge no debe desplazar en exceso los píxeles del borde"
        )
        precondition(MagnifierOptics.shouldRenderRefraction(reduceTransparency: false),
                     "La refracción debe estar disponible en apariencia normal")
        precondition(!MagnifierOptics.shouldRenderRefraction(reduceTransparency: true),
                     "Reduce Transparency debe desactivar la refracción")
        precondition(
            MagnifierOptics.outerLightAlpha(increaseContrast: true) >
            MagnifierOptics.outerLightAlpha(increaseContrast: false),
            "Increase Contrast debe reforzar el contorno óptico"
        )

        let areaForward = AreaSelectionGeometry.rect(
            from: CGPoint(x: 20, y: 30),
            to: CGPoint(x: 120, y: 90)
        )
        precondition(areaForward == CGRect(x: 20, y: 30, width: 100, height: 60))
        precondition(AreaSelectionGeometry.isMeaningful(areaForward))

        let areaReverse = AreaSelectionGeometry.rect(
            from: CGPoint(x: 120, y: 90),
            to: CGPoint(x: 20, y: 30)
        )
        precondition(areaReverse == areaForward, "Area debe normalizar el drag en cualquier dirección")

        let tinyArea = AreaSelectionGeometry.rect(
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 14, y: 16)
        )
        precondition(!AreaSelectionGeometry.isMeaningful(tinyArea), "Un clic o micro-drag no debe fijar un área")

        let guideBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        precondition(
            AreaGuideGeometry.preferredAxis(
                at: CGPoint(x: 200, y: 296),
                in: guideBounds,
                horizontalGuideY: nil,
                verticalGuideX: nil
            ) == .horizontal,
            "El borde superior debe originar una guía horizontal"
        )
        precondition(
            AreaGuideGeometry.preferredAxis(
                at: CGPoint(x: 3, y: 120),
                in: guideBounds,
                horizontalGuideY: nil,
                verticalGuideX: nil
            ) == .vertical,
            "El borde izquierdo debe originar una guía vertical"
        )
        precondition(
            AreaGuideGeometry.preferredAxis(
                at: CGPoint(x: 200, y: 151),
                in: guideBounds,
                horizontalGuideY: 150,
                verticalGuideX: nil
            ) == .horizontal,
            "Una guía existente debe poder volver a capturarse"
        )
        precondition(
            AreaGuideGeometry.clampedPosition(
                for: .horizontal,
                point: CGPoint(x: 30, y: 500),
                in: guideBounds
            ) == 300,
            "La guía horizontal no puede salir del Área"
        )
        precondition(
            AreaGuideGeometry.clampedPosition(
                for: .vertical,
                point: CGPoint(x: -20, y: 100),
                in: guideBounds
            ) == 0,
            "La guía vertical no puede salir del Área"
        )
        precondition(
            AreaGuideGeometry.shouldRemove(axis: .horizontal, position: 296, in: guideBounds),
            "Volver al borde superior debe eliminar la guía horizontal"
        )
        precondition(
            AreaGuideGeometry.shouldRemove(axis: .vertical, position: 4, in: guideBounds),
            "Volver al borde izquierdo debe eliminar la guía vertical"
        )
        precondition(
            !AreaGuideGeometry.shouldRemove(axis: .horizontal, position: 140, in: guideBounds) &&
            !AreaGuideGeometry.shouldRemove(axis: .vertical, position: 180, in: guideBounds),
            "Las guías interiores deben conservarse"
        )

        var gate = CaptureRequestGate()
        let first = gate.begin(displayID: 1)!
        for _ in 0..<600 {
            precondition(gate.begin(displayID: 1) == nil)
            precondition(gate.begin(displayID: 2) == nil)
        }
        gate.started(first)
        precondition(gate.begin(displayID: 1) == nil)
        let second = gate.begin(displayID: 2)!
        precondition(!gate.accepts(first), "Una captura anterior no puede publicar imágenes")
        precondition(!gate.fail(first), "Un error tardío no puede detener la captura nueva")
        precondition(gate.fail(second))
        precondition(!gate.fail(second), "Solo debe notificarse un error")
        gate.stop()
        for _ in 0..<600 {
            precondition(gate.begin(displayID: 1) == nil)
            precondition(gate.begin(displayID: 2) == nil)
        }
        gate.resetFailure()
        let third = gate.begin(displayID: 1)!
        gate.stop()
        precondition(!gate.accepts(third), "Cerrar durante el arranque invalida la respuesta")
        precondition(gate.begin(displayID: 1) != nil)
        print("OK: permiso único, captura Retina 1x/2x, Optical Edge, Area x1/x2/x3 + Guías, geometría de Area, concesión y revocación, 600 ciclos sin reintentos, cambio de pantalla, cierre durante arranque y respuestas tardías")
    }
}
