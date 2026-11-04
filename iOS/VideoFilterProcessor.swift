import CoreImage
import CoreVideo
import Metal
import Vision

/// Estilos de color para la cámara.
enum VideoLook: String, CaseIterable, Identifiable, Codable {
    case natural, warm, cool, vivid, cinema, soft, mono

    var id: String { rawValue }

    var name: String {
        switch self {
        case .natural: String(localized: "Natural")
        case .warm: String(localized: "Warm")
        case .cool: String(localized: "Cool")
        case .vivid: String(localized: "Vivid")
        case .cinema: String(localized: "Cinema")
        case .soft: String(localized: "Soft")
        case .mono: String(localized: "B&W")
        }
    }

    /// Colores de la muestra en el selector.
    var swatch: [(red: Double, green: Double, blue: Double)] {
        switch self {
        case .natural: [(0.85, 0.85, 0.85), (0.55, 0.55, 0.58)]
        case .warm: [(1.0, 0.78, 0.45), (0.9, 0.45, 0.25)]
        case .cool: [(0.6, 0.85, 1.0), (0.3, 0.45, 0.85)]
        case .vivid: [(1.0, 0.35, 0.55), (0.35, 0.8, 1.0)]
        case .cinema: [(1.0, 0.65, 0.35), (0.1, 0.45, 0.5)]
        case .soft: [(1.0, 0.88, 0.85), (0.85, 0.7, 0.85)]
        case .mono: [(0.95, 0.95, 0.95), (0.15, 0.15, 0.15)]
        }
    }
}

/// Aplica luz, color y fondo desenfocado a cada cuadro de video.
///
/// El fondo usa la segmentación de personas de Vision: se desenfoca y oscurece todo
/// lo que no es la persona, como el modo Retrato.
final class VideoFilterProcessor {
    struct Settings: Equatable {
        var look: VideoLook = .natural
        /// 0...1: más luz en la cara y sombras más suaves.
        var light: Double = 0
        /// 0...1: cuánto se desenfoca el fondo.
        var background: Double = 0

        var isNeutral: Bool { look == .natural && light < 0.01 && background < 0.01 }
    }

    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private let segmentation: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        // "fast" alcanza para un fondo desenfocado y deja aire a la grabación.
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private let sequenceHandler = VNSequenceRequestHandler()
    /// La segmentación corre aparte: el cuadro nunca la espera, usa la última máscara lista.
    private let segmentationQueue = DispatchQueue(label: "pronter.segmentation", qos: .userInitiated)
    private let maskLock = NSLock()
    private var latestMask: CVPixelBuffer?
    private var segmenting = false
    private(set) var segmentationFailed = false

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
    }

    /// Devuelve un cuadro nuevo con los filtros, o el mismo si no hay nada que aplicar.
    func process(_ pixelBuffer: CVPixelBuffer, settings: Settings) -> CVPixelBuffer {
        guard !settings.isNeutral else {
            return pixelBuffer
        }
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = source.extent
        var image = source

        let mask = settings.background > 0.01 ? personMask(for: pixelBuffer, extent: extent) : nil

        if settings.background > 0.01, let mask {
            let amount = settings.background
            // El desenfoque se calcula a un cuarto de resolución: se ve igual y es mucho más rápido.
            let down: CGFloat = 0.25
            let background = source
                .transformed(by: CGAffineTransform(scaleX: down, y: down))
                .clampedToExtent()
                .applyingGaussianBlur(sigma: (4 + amount * 22) * down)
                .transformed(by: CGAffineTransform(scaleX: 1 / down, y: 1 / down))
                .cropped(to: extent)
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.45 * amount])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 - 0.25 * amount])
            image = source.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: mask,
            ])
        }

        if settings.light > 0.01 {
            let light = settings.light
            image = image
                .applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputShadowAmount": 0.6 * light,
                    "inputHighlightAmount": 1 - 0.25 * light,
                ])
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.45 * light])
        }

        image = apply(settings.look, to: image, extent: extent)
        return render(image, extent: extent) ?? pixelBuffer
    }

    // MARK: Estilos

    private func apply(_ look: VideoLook, to image: CIImage, extent: CGRect) -> CIImage {
        switch look {
        case .natural:
            return image
        case .warm:
            return image
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.08, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1.01, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.86, w: 0),
                    "inputBiasVector": CIVector(x: 0.015, y: 0.005, z: 0, w: 0),
                ])
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.2])
        case .cool:
            return image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.9, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.99, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1.1, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0.005, z: 0.02, w: 0),
            ])
        case .vivid:
            return image
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.6])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1.06, kCIInputContrastKey: 1.04, kCIInputBrightnessKey: 0.01,
                ])
        case .cinema:
            return image
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0.85, kCIInputContrastKey: 1.06, kCIInputBrightnessKey: 0.015,
                ])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.05, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1.0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.95, w: 0),
                    "inputBiasVector": CIVector(x: -0.01, y: 0.012, z: 0.03, w: 0),
                ])
                .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.45, kCIInputRadiusKey: 1.8])
                .cropped(to: extent)
        case .soft:
            return image
                .applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: 12, kCIInputIntensityKey: 0.35])
                .cropped(to: extent)
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: 0.02, kCIInputContrastKey: 0.94, kCIInputSaturationKey: 0.96,
                ])
        case .mono:
            return image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0, kCIInputContrastKey: 1.08,
            ])
        }
    }

    // MARK: Retrato

    /// Máscara de la persona (blanco = persona), escalada al cuadro. Pide una nueva en
    /// segundo plano y mientras tanto usa la anterior.
    private func personMask(for pixelBuffer: CVPixelBuffer, extent: CGRect) -> CIImage? {
        maskLock.lock()
        let busy = segmenting
        let current = latestMask
        if !busy && !segmentationFailed { segmenting = true }
        maskLock.unlock()

        if !busy && !segmentationFailed {
            segmentationQueue.async { [weak self] in
                guard let self else { return }
                var result: CVPixelBuffer?
                var failed = false
                do {
                    try sequenceHandler.perform([segmentation], on: pixelBuffer)
                    result = segmentation.results?.first?.pixelBuffer
                } catch {
                    failed = true
                }
                maskLock.lock()
                if let result { latestMask = result }
                if failed { segmentationFailed = true }
                segmenting = false
                maskLock.unlock()
            }
        }

        guard let current else { return nil }
        let mask = CIImage(cvPixelBuffer: current)
        return mask
            .transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width,
                                               y: extent.height / mask.extent.height))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 3)
            .cropped(to: extent)
    }

    // MARK: Salida

    private func render(_ image: CIImage, extent: CGRect) -> CVPixelBuffer? {
        if pool == nil || poolSize != extent.size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(extent.width),
                kCVPixelBufferHeightKey as String: Int(extent.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            pool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            poolSize = extent.size
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard let output else { return nil }
        context.render(image, to: output, bounds: extent, colorSpace: colorSpace)
        return output
    }
}
