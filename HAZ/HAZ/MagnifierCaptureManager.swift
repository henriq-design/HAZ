import Cocoa
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import VideoToolbox

/// Solo convierte fotogramas en la cola de captura. No comparte estado mutable.
nonisolated private final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    let onFrame: @Sendable (CGImage) -> Void
    let onError: @Sendable (Error) -> Void

    init(onFrame: @escaping @Sendable (CGImage) -> Void,
         onError: @escaping @Sendable (Error) -> Void) {
        self.onFrame = onFrame
        self.onError = onError
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer else { return }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr,
              let image else { return }
        onFrame(image)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }
}

/// El ciclo de vida y la publicación de fotogramas pertenecen al actor principal.
@MainActor
final class MagnifierCaptureManager {
    struct Frame {
        let image: CGImage
        let displayID: CGDirectDisplayID
        let sequence: UInt64
    }

    enum CaptureError: LocalizedError {
        case screenNotFound
        case currentApplicationNotFound
        var errorDescription: String? {
            switch self {
            case .screenNotFound: return "No se ha podido localizar la pantalla para Magnifier."
            case .currentApplicationNotFound: return "No se ha podido excluir HAZ de la captura."
            }
        }
    }

    var onCaptureReady: ((CGDirectDisplayID, Double) -> Void)?
    var onCaptureError: ((Error) -> Void)?
    private let captureQueue = DispatchQueue(label: "org.hazapp.HAZ.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var output: CaptureOutput?
    private var storedFrame: Frame?
    private var sequence: UInt64 = 0
    private var gate = CaptureRequestGate()
    private var startTask: Task<Void, Never>?

    func start(for screen: NSScreen) {
        guard let displayID = Self.displayID(for: screen) else { return }
        guard let generation = gate.begin(displayID: displayID) else { return }
        let start = ProcessInfo.processInfo.systemUptime
        let previousStream = stream
        let previousOutput = output
        startTask?.cancel()
        stream = nil
        output = nil
        storedFrame = nil
        print("[HAZ] Inicio de captura: pantalla=\(displayID), solicitud=\(generation)")

        startTask = Task { [weak self] in
            // Finalizar la captura anterior antes de abrir otra.
            if let previousStream { try? await previousStream.stopCapture() }
            withExtendedLifetime(previousOutput) {}
            guard let self, self.gate.accepts(generation), !Task.isCancelled else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard self.gate.accepts(generation), !Task.isCancelled else { return }
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    throw CaptureError.screenNotFound
                }
                guard let ownApplication = content.applications.first(where: {
                    $0.processID == ProcessInfo.processInfo.processIdentifier
                }) else { throw CaptureError.currentApplicationNotFound }
                let filter = SCContentFilter(display: display, excludingApplications: [ownApplication], exceptingWindows: [])

                // SCDisplay dimensions are expressed in screen points. Capture at
                // the display's real pixel density so the magnifier does not
                // upscale an already-downsampled frame on Retina displays.
                let contentSizeInPoints: CGSize
                let pointPixelScale: CGFloat
                if #available(macOS 14.0, *) {
                    contentSizeInPoints = filter.contentRect.size
                    pointPixelScale = CGFloat(filter.pointPixelScale)
                } else {
                    contentSizeInPoints = CGSize(width: display.width, height: display.height)
                    pointPixelScale = screen.backingScaleFactor
                }
                let outputSize = CaptureGeometry.pixelSize(
                    contentSizeInPoints: contentSizeInPoints,
                    pointPixelScale: pointPixelScale
                )

                let configuration = SCStreamConfiguration()
                configuration.width = outputSize.width
                configuration.height = outputSize.height
                configuration.scalesToFit = false
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                configuration.queueDepth = 3
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.showsCursor = false
                configuration.capturesAudio = false

                print(
                    "[HAZ] captura nativa: " +
                    "\(Int(contentSizeInPoints.width))x\(Int(contentSizeInPoints.height)) pt, " +
                    "escala=\(String(format: "%.2f", Double(pointPixelScale))), " +
                    "salida=\(outputSize.width)x\(outputSize.height) px"
                )

                let receiver = CaptureOutput(onFrame: { [weak self] image in
                    Task { @MainActor [weak self] in
                        guard let self, self.gate.accepts(generation) else { return }
                        let firstFrame = self.storedFrame == nil
                        self.sequence &+= 1
                        self.storedFrame = Frame(image: image, displayID: displayID, sequence: self.sequence)
                        if firstFrame {
                            self.onCaptureReady?(displayID, (ProcessInfo.processInfo.systemUptime - start) * 1_000)
                        }
                    }
                }, onError: { [weak self] error in
                    Task { @MainActor [weak self] in self?.fail(error, generation: generation) }
                })
                let newStream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
                try newStream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: self.captureQueue)
                self.output = receiver
                self.stream = newStream
                try await newStream.startCapture()
                guard self.gate.accepts(generation), !Task.isCancelled else {
                    try? await newStream.stopCapture()
                    return
                }
                self.gate.started(generation)
            } catch {
                self.fail(error, generation: generation)
            }
        }
    }

    func stop() {
        gate.stop()
        startTask?.cancel()
        startTask = nil
        let previousOutput = output
        if let stream {
            Task {
                try? await stream.stopCapture()
                withExtendedLifetime(previousOutput) {}
            }
        }
        stream = nil
        output = nil
        storedFrame = nil
    }

    /// Solo una acción explícita permite reintentar después de un fallo.
    func resetFailure() { gate.resetFailure() }
    func latestFrame() -> Frame? { storedFrame }

    private func fail(_ error: Error, generation: UInt64) {
        guard gate.fail(generation) else { return }
        stop()
        onCaptureError?(error)
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
