import AVFoundation
import os
import Photos
import UIKit

/// Cámara propia con filtros en vivo: cada cuadro pasa por `VideoFilterProcessor`,
/// se muestra en pantalla y, al grabar, se escribe ya filtrado junto con el audio.
///
/// La sesión se configura en `sessionQueue`; los cuadros y el archivo, en `dataQueue`;
/// el estado publicado, en el hilo principal.
final class CameraModel: NSObject, ObservableObject, @unchecked Sendable {
    enum Status: Equatable {
        case starting
        case ready
        case unavailable(String)
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var position: AVCaptureDevice.Position = .front
    @Published var message: String?
    /// Se está hablando ahora (para "Seguir mi voz").
    @Published private(set) var isSpeaking = false

    @Published var look: VideoLook { didSet { filtersChanged() } }
    @Published var light: Double { didSet { filtersChanged() } }
    @Published var background: Double { didSet { filtersChanged() } }

    let session = AVCaptureSession()
    let previewView = SampleBufferView()

    private let displayLayer: AVSampleBufferDisplayLayer
    private let sessionQueue = DispatchQueue(label: "pronter.camera.session")
    private let dataQueue = DispatchQueue(label: "pronter.camera.data", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let processor = VideoFilterProcessor()
    private let filterState = OSAllocatedUnfairLock(initialState: VideoFilterProcessor.Settings())
    private var videoInput: AVCaptureDeviceInput?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var configured = false

    // Solo en `dataQueue`.
    private var writer: VideoWriter?
    private var wantsRecording = false
    private var audioSettings: [String: Any]?
    private var displayFormat: CMVideoFormatDescription?
    private var noiseFloor: Float = -50
    private var loudSince: CFTimeInterval?
    private var lastLoud: CFTimeInterval = 0
    private var speaking = false

    var canRecord: Bool { status == .ready }

    override init() {
        let defaults = UserDefaults.standard
        look = VideoLook(rawValue: defaults.string(forKey: "camera.look") ?? "") ?? .natural
        light = defaults.object(forKey: "camera.light") as? Double ?? 0
        background = defaults.object(forKey: "camera.background") as? Double ?? 0
        displayLayer = previewView.displayLayer
        super.init()
        displayLayer.videoGravity = .resizeAspectFill
        filtersChanged()
    }

    // MARK: Ciclo de vida

    func start() {
        Task { @MainActor [weak self] in
            guard await Self.requestAccess(for: .video) else {
                self?.status = .unavailable(String(localized: "Allow camera access in Settings › Cue."))
                return
            }
            let hasMicrophone = await Self.requestAccess(for: .audio)
            self?.sessionQueue.async { [weak self] in
                self?.configureIfNeeded(withAudio: hasMicrophone)
                self?.session.startRunning()
            }
        }
    }

    func stop() {
        stopRecording()
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    func flip() {
        guard !isRecording else { return }
        let newPosition: AVCaptureDevice.Position = position == .front ? .back : .front
        sessionQueue.async { [weak self] in
            guard let self, let device = Self.camera(at: newPosition),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            if let videoInput { session.removeInput(videoInput) }
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
                Self.limitFrameRate(of: device)
            } else if let videoInput {
                session.addInput(videoInput)
            }
            session.commitConfiguration()
            configureVideoConnection()
            DispatchQueue.main.async {
                self.position = newPosition
                self.updateOrientation()
            }
        }
    }

    // MARK: Grabación

    func startRecording() {
        guard canRecord, !isRecording else { return }
        isRecording = true
        recordingStartedAt = Date()
        dataQueue.async { [weak self] in self?.wantsRecording = true }
    }

    func stopRecording() {
        guard isRecording else { return }
        dataQueue.async { [weak self] in
            guard let self else { return }
            wantsRecording = false
            guard let writer else {
                finishRecording(url: nil)
                return
            }
            self.writer = nil
            writer.finish { [weak self] url in self?.finishRecording(url: url) }
        }
    }

    private func finishRecording(url: URL?) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingStartedAt = nil
        }
        if let url {
            saveToPhotos(url)
        } else {
            show(String(localized: "The recording couldn't be saved"))
        }
    }

    // MARK: Filtros

    private func filtersChanged() {
        let settings = VideoFilterProcessor.Settings(look: look, light: light, background: background)
        filterState.withLock { $0 = settings }
        let defaults = UserDefaults.standard
        defaults.set(look.rawValue, forKey: "camera.look")
        defaults.set(light, forKey: "camera.light")
        defaults.set(background, forKey: "camera.background")
    }

    // MARK: Configuración

    private func configureIfNeeded(withAudio: Bool) {
        guard !configured else { return }
        guard let device = Self.camera(at: position),
              let input = try? AVCaptureDeviceInput(device: device) else {
            DispatchQueue.main.async {
                self.status = .unavailable(String(localized: "This device has no camera available. You can still try the prompter."))
            }
            return
        }
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        }
        Self.limitFrameRate(of: device)
        if withAudio, let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if withAudio {
            audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        }
        session.commitConfiguration()
        configureVideoConnection()
        let settings = withAudio ? audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) : nil
        dataQueue.async { [weak self] in self?.audioSettings = settings }
        configured = true
        DispatchQueue.main.async {
            self.status = .ready
            self.updateOrientation()
        }
    }

    /// El archivo se graba sin espejo (como la app Cámara); la vista previa sí se ve en espejo.
    private func configureVideoConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    /// Mantiene el video derecho al girar el teléfono (no cambia a mitad de una grabación).
    private func updateOrientation() {
        previewView.transform = position == .front ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        guard let device = videoInput?.device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewView.layer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            self?.sessionQueue.async { [weak self] in
                guard let self, !self.isRecording,
                      let connection = videoOutput.connection(with: .video),
                      connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        }
    }

    /// 30 cuadros por segundo: suficiente para hablar a cámara y deja margen a los filtros.
    private static func limitFrameRate(of device: AVCaptureDevice) {
        let frameDuration = CMTime(value: 1, timescale: 30)
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameDuration <= frameDuration && frameDuration <= $0.maxFrameDuration
        }
        guard supported, (try? device.lockForConfiguration()) != nil else { return }
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        device.unlockForConfiguration()
    }

    // MARK: Voz

    /// Detecta si se está hablando con un piso de ruido que se adapta al lugar.
    private func updateVoice(level: Float) {
        let now = CACurrentMediaTime()
        if level < noiseFloor {
            noiseFloor = level
        } else {
            noiseFloor += (level - noiseFloor) * 0.002
        }
        let threshold = max(noiseFloor + 12, -42)
        if level > threshold {
            lastLoud = now
            if loudSince == nil { loudSince = now }
        }
        var nowSpeaking = speaking
        if !speaking, let loudSince, now - loudSince > 0.12 {
            nowSpeaking = true
        } else if speaking, now - lastLoud > 0.9 {
            nowSpeaking = false
            loudSince = nil
        }
        if now - lastLoud > 0.2 && !nowSpeaking { loudSince = nil }
        guard nowSpeaking != speaking else { return }
        speaking = nowSpeaking
        DispatchQueue.main.async { self.isSpeaking = nowSpeaking }
    }

    private static func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
    }

    private static func requestAccess(for type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    // MARK: Vista previa

    private func display(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        let formatMatches = displayFormat.map { CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer) } ?? false
        if !formatMatches {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &displayFormat)
        }
        guard let displayFormat else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: displayFormat, sampleTiming: &timing,
                                                 sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sampleBuffer)
    }

    // MARK: Guardado

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: url)
                self.show(String(localized: "Couldn't save: allow access to Photos in Settings."))
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, _ in
                try? FileManager.default.removeItem(at: url)
                self.show(success ? String(localized: "Video saved to Photos") : String(localized: "Couldn't save the video"))
            }
        }
    }

    private func show(_ text: String) {
        DispatchQueue.main.async { self.message = text }
    }
}

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            writer?.appendAudio(sampleBuffer)
            if let level = connection.audioChannels.first?.averagePowerLevel {
                updateVoice(level: level)
            }
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let settings = filterState.withLock { $0 }
        let frame = processor.process(pixelBuffer, settings: settings)

        if wantsRecording && writer == nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pronter-\(UUID().uuidString).mov")
            do {
                writer = try VideoWriter(url: url, width: CVPixelBufferGetWidth(frame),
                                         height: CVPixelBufferGetHeight(frame), audioSettings: audioSettings)
            } catch {
                wantsRecording = false
                finishRecording(url: nil)
            }
        }
        writer?.appendVideo(frame, at: time)
        display(frame, at: time)
    }
}
