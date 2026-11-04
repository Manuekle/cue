import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noMicrophone, noDisplay

    var errorDescription: String? {
        switch self {
        case .noMicrophone: String(localized: "No microphone available.")
        case .noDisplay: String(localized: "No display found to capture system audio.")
        }
    }
}

/// Convierte cualquier formato de audio a 16 kHz mono Float32, lo que espera Whisper.
final class Resampler {
    static let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: Self.whisperFormat)
            converter?.downmix = true
        }
        guard let converter, buffer.frameLength > 0 else { return [] }
        let ratio = Self.whisperFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.whisperFormat, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}

/// Tu voz, desde el micrófono.
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let resampler = Resampler()
    /// Se llama en el hilo de audio.
    var onSamples: (([Float]) -> Void)?

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.resampler.convert(buffer)
            if !samples.isEmpty { self.onSamples?(samples) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// El audio que suena en el Mac (la otra persona en Zoom, Meet, FaceTime…), con ScreenCaptureKit.
/// Excluye el audio de Pronter. Pide el permiso "Grabación de pantalla y audio del sistema".
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let resampler = Resampler()
    private let queue = DispatchQueue(label: "pronter.system-audio")
    /// Se llaman en una cola de fondo.
    var onSamples: (([Float]) -> Void)?
    var onStop: ((Error) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // El video no se usa: lo mínimo posible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        let stream = stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = sampleBuffer.pcmBuffer() else { return }
        let samples = resampler.convert(buffer)
        if !samples.isEmpty { onSamples?(samples) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}

private extension CMSampleBuffer {
    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard let description = formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(self, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

/// Corta el audio en frases con un detector de voz por energía: cierra la frase tras ~0,7 s de silencio
/// o a los 14 s. Úsalo siempre desde el mismo hilo.
final class SpeechSegmenter {
    private static let frameLength = 480          // 30 ms a 16 kHz
    private static let silenceToClose = 23        // ≈ 0,7 s
    private static let minSpeechFrames = 12       // ≈ 0,36 s de voz
    private static let maxSamples = 16_000 * 14
    private static let preRollFrames = 10         // 0,3 s antes de que empiece la voz

    private var pending: [Float] = []
    private var current: [Float] = []
    private var preRoll: [Float] = []
    private var speechFrames = 0
    private var silenceFrames = 0
    private var noiseFloor: Float = 0.004
    /// Nivel de voz reciente (0…1), para dibujar el indicador.
    private(set) var level: Float = 0

    var onSegment: (([Float]) -> Void)?

    func append(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        var start = 0
        while pending.count - start >= Self.frameLength {
            process(pending[start..<start + Self.frameLength])
            start += Self.frameLength
        }
        pending.removeFirst(start)
    }

    private func process(_ frame: ArraySlice<Float>) {
        var sum: Float = 0
        for sample in frame { sum += sample * sample }
        let rms = (sum / Float(frame.count)).squareRoot()
        level = level * 0.7 + min(1, rms * 12) * 0.3
        let voiced = rms > max(0.01, noiseFloor * 3)
        // El ruido de fondo se adapta rápido en silencio y muy lento con voz.
        let rate: Float = voiced ? 0.0005 : 0.01
        noiseFloor += (rms - noiseFloor) * rate

        if current.isEmpty && !voiced {
            preRoll.append(contentsOf: frame)
            let limit = Self.frameLength * Self.preRollFrames
            if preRoll.count > limit { preRoll.removeFirst(preRoll.count - limit) }
            return
        }
        if current.isEmpty {
            current = preRoll
            preRoll.removeAll()
        }
        current.append(contentsOf: frame)
        if voiced {
            speechFrames += 1
            silenceFrames = 0
        } else {
            silenceFrames += 1
        }
        if silenceFrames >= Self.silenceToClose || current.count >= Self.maxSamples { flush() }
    }

    func flush() {
        let segment = current
        let enoughSpeech = speechFrames >= Self.minSpeechFrames
        current.removeAll()
        speechFrames = 0
        silenceFrames = 0
        if enoughSpeech { onSegment?(segment) }
    }
}
