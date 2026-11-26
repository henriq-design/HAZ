#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    selected_developer_dir="$(xcode-select -p 2>/dev/null || true)"
    if [[ -z "$selected_developer_dir" || "$selected_developer_dir" == *"/CommandLineTools"* ]]; then
        print -u2 'Error: selecciona una instalación completa de Xcode con xcode-select o define DEVELOPER_DIR.'
        exit 1
    fi
fi

mkdir -p "$project_root/Build/Tests"

xcrun swiftc -swift-version 6 -default-isolation MainActor -strict-concurrency=complete -warnings-as-errors \
    "$project_root/HAZ/ScreenCapturePermission.swift" \
    "$project_root/HAZ/CaptureRequestGate.swift" \
    "$project_root/HAZ/CaptureGeometry.swift" \
    "$project_root/HAZ/MagnifierOptics.swift" \
    "$project_root/HAZ/HAZPreferences.swift" \
    "$project_root/HAZ/SettingsWindowController.swift" \
    "$project_root/HAZ/OnboardingWindowController.swift" \
    "$project_root/HAZ/HAZTool.swift" \
    "$project_root/HAZ/AreaLevel.swift" \
    "$project_root/HAZ/AreaGuideGeometry.swift" \
    "$project_root/HAZ/AreaSelectionGeometry.swift" \
    "$project_root/Tests/PermissionRegressionTests.swift" \
    -o "$project_root/Build/Tests/PermissionRegressionTests"

"$project_root/Build/Tests/PermissionRegressionTests"

pbx="$project_root/HAZ.xcodeproj/project.pbxproj"
scheme="$project_root/HAZ.xcodeproj/xcshareddata/xcschemes/HAZ.xcscheme"
app_delegate="$project_root/HAZ/AppDelegate.swift"
catalog="$project_root/HAZ/Localizable.xcstrings"
capture_manager="$project_root/HAZ/MagnifierCaptureManager.swift"
flashlight_view="$project_root/HAZ/FlashlightView.swift"
hotkeys="$project_root/HAZ/GlobalHotKeyManager.swift"
preferences="$project_root/HAZ/HAZPreferences.swift"
settings="$project_root/HAZ/SettingsWindowController.swift"
onboarding="$project_root/HAZ/OnboardingWindowController.swift"

check_contains() {
    local needle="$1"
    local file="$2"
    local label="$3"
    if grep -Fq "$needle" "$file"; then
        print "OK: $label"
    else
        print -u2 "FALLO: $label"
        exit 1
    fi
}

check_absent() {
    local needle="$1"
    local file="$2"
    local label="$3"
    if grep -Fq "$needle" "$file"; then
        print -u2 "FALLO: $label"
        exit 1
    else
        print "OK: $label"
    fi
}

[[ $(grep -Fc 'PRODUCT_BUNDLE_IDENTIFIER = org.hazapp.HAZ;' "$pbx") == 2 ]] || { print -u2 'FALLO: Bundle ID candidato'; exit 1; }
check_contains 'path = HAZ.app;' "$pbx" 'producto renombrado HAZ.app'
check_contains 'name = HAZ;' "$pbx" 'target Xcode renombrado HAZ'
check_contains 'path = HAZ;' "$pbx" 'grupo sincronizado HAZ'
check_contains 'BuildableName = "HAZ.app"' "$scheme" 'scheme usa HAZ.app'
check_contains 'BlueprintName = "HAZ"' "$scheme" 'scheme apunta a target HAZ'
check_contains 'ReferencedContainer = "container:HAZ.xcodeproj"' "$scheme" 'scheme apunta a HAZ.xcodeproj'
check_absent 'DEVELOPMENT_TEAM =' "$pbx" 'sin equipo de firma personal'
check_contains 'CODE_SIGN_IDENTITY = "-";' "$pbx" 'firma ad hoc'
check_contains 'INFOPLIST_KEY_CFBundleDisplayName = HAZ;' "$pbx" 'nombre visible HAZ'
check_contains 'developmentRegion = es;' "$pbx" 'español como idioma fuente'
check_contains 'private let preferences: HAZPreferences' "$app_delegate" 'AppDelegate consume el modelo central de preferencias'
check_absent 'UserDefaults.standard' "$app_delegate" 'AppDelegate ya no persiste preferencias directamente'
check_contains 'static let activationMode = "activationMode"' "$preferences" 'se conserva la key activationMode'
check_contains 'static let radius = "circleRadius"' "$preferences" 'se conserva la key circleRadius'
check_contains 'static let dimAlpha = "dimAlpha"' "$preferences" 'se conserva la key dimAlpha'
check_contains 'static let displayScope = "displayScope"' "$preferences" 'se conserva la key displayScope'
check_contains 'static let zoomLevel = "zoomLevel"' "$preferences" 'se conserva la key zoomLevel'
check_contains 'static let hasCompletedOnboarding = "hasCompletedOnboarding"' "$preferences" 'onboarding conserva estado de primer uso'
check_contains 'func observe(_ observer:' "$preferences" 'preferencias admiten múltiples consumidores sincronizados'
check_contains 'SettingsWindowController(preferences: preferences)' "$app_delegate" 'menubar abre Settings sobre el mismo modelo'
check_contains 'deactivateActiveTool(reason: "open settings")' "$app_delegate" 'Settings no queda debajo de un overlay activo'
check_contains 'keyEquivalent: ","' "$app_delegate" 'Settings expone el atajo estándar ⌘,'
check_contains 'private let activationControl' "$settings" 'Settings expone activación de Lupa'
check_contains 'private let zoomControl' "$settings" 'Settings expone nivel inicial de Lupa'
check_contains 'private let sizeControl' "$settings" 'Settings expone tamaño de Lupa'
check_contains 'private let displaysControl' "$settings" 'Settings expone alcance de pantallas'
check_contains 'private let dimmingControl' "$settings" 'Settings expone oscurecimiento compartido'
check_contains 'window.collectionBehavior = [.moveToActiveSpace]' "$settings" 'Settings reaparece en el Space activo'
check_absent 'UserDefaults' "$settings" 'Settings no crea una segunda fuente de verdad'
check_contains '"settings.zoomLevel"' "$catalog" 'Settings localiza el nivel en ES/EN/zh-Hans'
check_contains '"settings.section.shared"' "$catalog" 'Settings documenta el oscurecimiento compartido'
check_absent 'SMAppService' "$settings" 'v0.6.0 no adelanta Launch at Login'
check_contains 'guard !preferences.hasCompletedOnboarding else { return }' "$app_delegate" 'onboarding se muestra una sola vez'
check_contains 'OnboardingWindowController(' "$app_delegate" 'AppDelegate presenta onboarding nativo'
check_contains 'self?.ensureScreenCaptureAccessForActivation() ?? false' "$app_delegate" 'onboarding reutiliza el gate TCC existente'
check_absent 'CGRequestScreenCaptureAccess' "$onboarding" 'onboarding no crea una solicitud TCC paralela'
check_contains '@objc private func requestPermission' "$onboarding" 'permiso solo se solicita tras acción explícita'
check_contains 'requestScreenCaptureAccess()' "$onboarding" 'acción de permiso usa la dependencia inyectada'
check_contains '@objc private func skipOnboarding' "$onboarding" 'onboarding se puede omitir'
check_contains 'windowWillClose' "$onboarding" 'cerrar onboarding respeta la decisión del usuario'
check_contains 'window.collectionBehavior = [.moveToActiveSpace]' "$onboarding" 'onboarding aparece en el Space activo'
check_contains '"onboarding.permission.body"' "$catalog" 'explicación TCC localizada en ES/EN/zh-Hans'
check_contains '"onboarding.skip"' "$catalog" 'acción Omitir localizada en ES/EN/zh-Hans'
check_absent 'SMAppService' "$onboarding" 'v0.6.1 no adelanta Launch at Login'
check_contains 'NSImage(named: NSImage.Name(imageName))' "$app_delegate" 'menubar usa assets HAZ'
check_absent 'flashlight.on.fill' "$app_delegate" 'sin SF Symbol flashlight.on.fill'
check_absent 'flashlight.off.fill' "$app_delegate" 'sin SF Symbol flashlight.off.fill'
check_contains 'filter.pointPixelScale' "$capture_manager" 'captura Retina usa pointPixelScale en macOS 14+'
check_contains 'screen.backingScaleFactor' "$capture_manager" 'captura Retina conserva fallback macOS 13'
check_contains 'configuration.scalesToFit = false' "$capture_manager" 'captura evita reescalado adicional'
check_contains 'default: return .medium' "$flashlight_view" 'interpolación media por defecto'
check_absent 'drawLensBorder' "$flashlight_view" 'Magnifier elimina el borde azul clásico'
check_contains 'drawRefractedEdge' "$flashlight_view" 'Optical Edge refracta solo la banda perimetral'
check_contains 'annulus.appendOval(in: bandOuterRect)' "$flashlight_view" 'refracción recorta el borde exterior por anillos'
check_contains 'annulus.appendOval(in: bandInnerRect)' "$flashlight_view" 'refracción recorta el borde interior por anillos'
check_contains 'annulus.windingRule = .evenOdd' "$flashlight_view" 'refracción mantiene máscara anular acotada'
check_contains 'drawOpticalRim' "$flashlight_view" 'Magnifier dibuja contorno óptico neutro'
check_contains 'accessibilityDisplayShouldReduceTransparency' "$flashlight_view" 'Optical Edge respeta Reduce Transparency'
check_contains 'accessibilityDisplayShouldIncreaseContrast' "$flashlight_view" 'Optical Edge respeta Increase Contrast'
check_contains 'radius: max(circleRadius - 1.4, 1)' "$flashlight_view" 'highlight especular queda limitado al perímetro'
check_contains 'static let edgeWidth: CGFloat = 8.0' "$project_root/HAZ/MagnifierOptics.swift" 'banda óptica suavizada a 8 pt'
check_contains 'static let refractionStrength: CGFloat = 0.006' "$project_root/HAZ/MagnifierOptics.swift" 'refracción máxima reducida al 0,6%'
check_contains 'static let refractionBandCount = 4' "$project_root/HAZ/MagnifierOptics.swift" 'refracción usa cuatro anillos de transición'
check_contains 'for band in 0..<bandCount' "$flashlight_view" 'Optical Edge distribuye la refracción progresivamente'
check_contains 'smoothstep falloff' "$project_root/HAZ/MagnifierOptics.swift" 'caída óptica documentada y acotada'
check_contains 'kVK_ANSI_A' "$hotkeys" 'atajo global Area usa ⌃⌥A'
check_contains 'onAreaPressed' "$hotkeys" 'evento global Area conectado'
check_contains 'case .area:' "$app_delegate" 'arquitectura HAZTool integra Area'
check_contains 'if self.activeTool == .area {' "$app_delegate" 'zoom contextual detecta Area'
check_contains 'self.setAreaLevel(' "$app_delegate" 'Area enruta x1/x2/x3 dentro de la misma entidad'
check_contains '"HAZ-active"' "$app_delegate" 'menubar representa Area con estado activo HAZ'
check_contains 'isAreaSelectionArmed' "$flashlight_view" 'Area intercepta ratón solo durante selección'
check_contains 'acceptsFirstMouse' "$flashlight_view" 'Area acepta el primer drag sin activar HAZ'
check_contains 'appendOval(in: lensRect(centeredAt: center))' "$flashlight_view" 'Magnifier conserva un recorte circular sin halo cuadrado'
check_contains 'drawAreaMagnifiedFrame' "$flashlight_view" 'Area x2/x3 amplía dentro del mismo rectángulo'
check_contains 'areaMagnification > 1.0' "$flashlight_view" 'Area x1 permanece sin reescalado'
check_contains 'AreaGuideInteractionView' "$app_delegate" 'Area ampliada bloquea clics dentro de la región'
check_contains 'selectedAreaOverlay' "$app_delegate" 'Area se mantiene ligada a la pantalla seleccionada'
check_contains 'ensureScreenCaptureAccessForActivation' "$app_delegate" 'Area x2/x3 reutiliza el flujo TCC estable'
check_contains '.now() + 0.70' "$app_delegate" 'HUD de Area desaparece a los 0,7 s'
check_contains 'line.lineWidth = 1.0' "$flashlight_view" 'Guías mantienen trazo sutil de 1 pt'
check_contains 'return 0.60' "$flashlight_view" 'Guías en reposo usan opacidad sutil'
check_contains 'return 0.80' "$flashlight_view" 'Guías en hover aumentan contraste sin engordar'
check_contains 'return 1.0' "$flashlight_view" 'Guías durante drag usan contraste completo sin engordar'
check_contains 'rail.lineWidth = 2.0' "$flashlight_view" 'orígenes de Guías tienen affordance sutil de 2 pt'
check_contains 'return 0.70' "$flashlight_view" 'orígenes de Guías reposan al 70%'
check_contains 'drawAreaGuideOrigins' "$flashlight_view" 'Area muestra orígenes de Guías en x1/x2/x3'
check_contains 'refreshAreaInteractionWindows()' "$app_delegate" 'Area refresca zonas mínimas de interacción de Guías'
check_contains 'if areaLevel.requiresCapture {' "$app_delegate" 'Area distingue interacción x1 frente a x2/x3'
check_contains 'fixedAxis: .horizontal' "$app_delegate" 'Area x1 expone solo hit target horizontal de Guías'
check_contains 'fixedAxis: .vertical' "$app_delegate" 'Area x1 expone solo hit target vertical de Guías'
check_contains 'areaInteractionWindows = windows' "$app_delegate" 'Area x1 mantiene click-through fuera de zonas de Guías'
check_contains 'sourceInset: CGFloat = 8' "$project_root/HAZ/AreaGuideGeometry.swift" 'Guías nacen desde una zona de borde contenida'
check_contains 'horizontalGuideY' "$app_delegate" 'Area permite una única guía horizontal'
check_contains 'verticalGuideX' "$app_delegate" 'Area permite una única guía vertical'
check_contains 'resizeUpDown' "$app_delegate" 'cursor comunica guía horizontal'
check_contains 'resizeLeftRight' "$app_delegate" 'cursor comunica guía vertical'
check_absent 'Inspect' "$app_delegate" 'naming Inspect eliminado del producto'

for required in \
    "$project_root/HAZ/Assets.xcassets/HAZ-inactive.imageset/Contents.json" \
    "$project_root/HAZ/Assets.xcassets/HAZ-magnifier.imageset/Contents.json" \
    "$project_root/HAZ/Assets.xcassets/HAZ-active.imageset/Contents.json" \
    "$project_root/HAZ/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"; do
    if [[ -f "$required" ]]; then
        print "OK: asset presente -> ${required:t}"
    else
        print -u2 "FALLO: falta asset -> $required"
        exit 1
    fi
done

area_activation_block="$(sed -n '/private func activateAreaSelection/,/private func completeAreaSelection/p' "$app_delegate")"
if print -r -- "$area_activation_block" | grep -Fq 'ensureScreenCaptureAccessForActivation'; then
    print -u2 'FALLO: Area no debe depender de Screen Recording.'
    exit 1
else
    print 'OK: Area funciona sin permiso de Screen Recording'
fi

area_level_block="$(sed -n '/private func setAreaLevel/,/private func selectedAreaOverlay/p' "$app_delegate")"
if print -r -- "$area_level_block" | grep -Fq 'ensureScreenCaptureAccessForActivation'; then
    print 'OK: Area x2/x3 reutiliza el permiso de Screen Recording'
else
    print -u2 'FALLO: Area x2/x3 debe pasar por el flujo TCC estable.'
    exit 1
fi

if grep -Eiq 'Inspect|Inspeccionar|Detalle|Detail' "$app_delegate" "$catalog"; then
    print -u2 'FALLO: Area debe ser la única entidad visible para x1/x2/x3.'
    exit 1
else
    print 'OK: naming visible unifica x1/x2/x3 bajo Area'
fi

localization_check_dir="$project_root/Build/Tests/LocalizationCheck"
rm -rf "$localization_check_dir"
mkdir -p "$localization_check_dir"

if xcrun xcstringstool compile --dry-run --output-directory "$localization_check_dir" "$catalog" >/dev/null; then
    print 'OK: catálogo de localización válido'
else
    print -u2 'FALLO: xcstringstool no puede compilar Localizable.xcstrings'
    exit 1
fi

# Evita que este propio test se detecte a sí mismo: contiene el patrón de ruta.
if grep -Eq '/Users/[^/]+/' "$project_root/scripts/build.sh" "$project_root/../README.md"; then
    print -u2 'Error: quedan rutas personales en README o build.sh.'
    exit 1
fi

print 'OK: identidad candidata comprobada estáticamente, Magnifier Optical Edge + Area x1/x2/x3 + Guías integrados, assets y localización presentes.'
