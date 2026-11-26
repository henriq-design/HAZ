import CoreGraphics

/// El estado solo se consulta al activar o revisar; nunca desde el temporizador.
@MainActor
final class ScreenCapturePermission {
    private let preflight: () -> Bool
    private let request: () -> Bool
    private(set) var didRequest = false

    init(preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         request: @escaping () -> Bool = { CGRequestScreenCaptureAccess() }) {
        self.preflight = preflight
        self.request = request
    }

    var isGranted: Bool { preflight() }

    func ensureAccess() -> Bool {
        if preflight() { return true }
        guard !didRequest else { return false }
        // Marcar antes de entrar en la llamada nativa, que puede mostrar un diálogo.
        didRequest = true
        print("[HAZ] Solicitud nativa de permiso de pantalla (única por proceso)")
        _ = request()
        return preflight()
    }
}
