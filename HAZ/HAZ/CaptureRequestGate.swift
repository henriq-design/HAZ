/// Evita reintentos desde el temporizador y descarta respuestas de sesiones antiguas.
struct CaptureRequestGate {
    private(set) var generation: UInt64 = 0
    private var displayID: UInt32?
    private var isStarting = false
    private(set) var isBlocked = false

    mutating func begin(displayID: UInt32) -> UInt64? {
        guard !isBlocked, !isStarting, self.displayID != displayID else { return nil }
        generation &+= 1
        self.displayID = displayID
        isStarting = true
        return generation
    }

    func accepts(_ generation: UInt64) -> Bool {
        self.generation == generation && displayID != nil && !isBlocked
    }

    mutating func started(_ generation: UInt64) {
        if accepts(generation) { isStarting = false }
    }

    mutating func fail(_ generation: UInt64) -> Bool {
        guard accepts(generation) else { return false }
        isBlocked = true
        isStarting = false
        return true
    }

    mutating func stop() {
        generation &+= 1
        displayID = nil
        isStarting = false
    }

    mutating func resetFailure() {
        stop()
        isBlocked = false
    }
}
