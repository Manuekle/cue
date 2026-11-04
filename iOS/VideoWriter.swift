import AVFoundation

/// Escribe en un .mov los cuadros ya filtrados más el audio del micrófono.
/// Se usa siempre desde la misma cola que entrega los cuadros.
final class VideoWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private var started = false

    init(url: URL, width: Int, height: Int, audioSettings: [String: Any]?) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 5],
        ]
        if !writer.canApply(outputSettings: videoSettings, forMediaType: .video) {
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.h264
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        if writer.canAdd(videoInput) { writer.add(videoInput) }

        if let audioSettings, writer.canApply(outputSettings: audioSettings, forMediaType: .audio) {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            started = true
        }
        guard writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
        adaptor.append(pixelBuffer, withPresentationTime: time)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard started, writer.status == .writing, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    /// Cierra el archivo. Devuelve la URL si quedó bien escrito.
    func finish(_ completion: @escaping (URL?) -> Void) {
        guard started else {
            writer.cancelWriting()
            completion(nil)
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [writer, url] in
            completion(writer.status == .completed ? url : nil)
        }
    }
}
