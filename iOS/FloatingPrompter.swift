import AVKit
import Combine
import OSLog
import UIKit

private let log = Logger(subsystem: "com.manudev.pronter", category: "floating")

/// Ventana flotante (Picture in Picture) que muestra el prompter encima de cualquier app:
/// Cámara, Instagram, TikTok, WhatsApp, Zoom…
///
/// Arranque automático: mientras la ventana está abierta, Cue mantiene activa una sesión
/// de audio de reproducción. Cuando otra app empieza a grabar, iOS interrumpe esa sesión:
/// esa es la señal para contar y arrancar. Cuando deja de grabar, la interrupción termina
/// y el texto se pausa. No usa el micrófono.
final class FloatingPrompter: NSObject, ObservableObject {
    enum WindowState: Equatable {
        case preparing
        case ready
        case open
        case failed(String)

        var label: String {
            switch self {
            case .preparing: String(localized: "Preparing the window…")
            case .ready: String(localized: "Ready to open")
            case .open: String(localized: "Open over your apps")
            case .failed(let reason): reason
            }
        }
    }

    @Published private(set) var windowState: WindowState = .preparing
    @Published private(set) var lastSignal: String?

    var isActive: Bool { windowState == .open }

    let isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    let engine = PrompterEngine()
    let hostView = SampleBufferView()

    private let settings: PrompterSettings
    private let displayLayer: AVSampleBufferDisplayLayer
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var frameTimer: DispatchSourceTimer?
    private var cancellables = Set<AnyCancellable>()
    private var interruptionObserver: NSObjectProtocol?
    private var otherAppRecording = false
    private var startWhenPossible = false

    /// Activar la sesión de audio puede tardar: nunca en el hilo principal.
    private let audioQueue = DispatchQueue(label: "pronter.floating.audio", qos: .userInitiated)

    // Dibujo en su propia cola para no frenar la interfaz.
    private let renderQueue = DispatchQueue(label: "pronter.floating.render", qos: .userInitiated)
    private var renderer: PrompterFrameRenderer
    private var lastState: PrompterFrameRenderer.State?
    private var lastFrameTime: CFTimeInterval = 0

    /// La letra en la ventana flotante es más grande: la ventana se ve chica.
    private let fontScale: CGFloat = 2.1

    init(settings: PrompterSettings) {
        self.settings = settings
        displayLayer = hostView.displayLayer
        renderer = Self.makeRenderer(vertical: settings.floatingVertical)
        super.init()
        engine.wordsPerMinute = settings.wordsPerMinute
        engine.countdownSeconds = settings.countdown
        settings.$wordsPerMinute.sink { [weak self] in self?.engine.wordsPerMinute = $0 }.store(in: &cancellables)
        settings.$countdown.sink { [weak self] in self?.engine.countdownSeconds = $0 }.store(in: &cancellables)
        settings.$floatingVertical
            .dropFirst()
            .sink { [weak self] vertical in self?.changeOrientation(vertical: vertical) }
            .store(in: &cancellables)
        engine.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.controller?.invalidatePlaybackState() }
            .store(in: &cancellables)
    }

    func prepare(text: String) {
        log.notice("prepare: PiP supported=\(self.isSupported)")
        engine.load(text: text, reset: true)
        setUpTimebase()
        startFrames()
        guard isSupported else {
            windowState = .failed(String(localized: "This iPhone doesn't support floating windows"))
            return
        }
        activateAudioSession()
        setUpController()
        observeInterruptions()
    }

    func toggleWindow() {
        guard let controller else {
            log.error("toggle sin controlador")
            return
        }
        log.notice("toggle: active=\(controller.isPictureInPictureActive) possible=\(controller.isPictureInPicturePossible)")
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            // Aún no hay cuadros suficientes: se abre en cuanto sea posible.
            startWhenPossible = true
            windowState = .preparing
        }
    }

    func tearDown() {
        controller?.stopPictureInPicture()
        engine.pause()
        frameTimer?.cancel()
        frameTimer = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        audioQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Audio y arranque automático

    private func activateAudioSession() {
        audioQueue.async {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
            } catch {
                log.error("sesión de audio: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let reasonRaw = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
        let reason = reasonRaw.flatMap(AVAudioSession.InterruptionReason.init(rawValue:)) ?? .default
        log.notice("interrupción \(type == .began ? "empezó" : "terminó", privacy: .public) motivo=\(reason.rawValue) pip=\(self.isActive) fase=\(String(describing: self.engine.phase), privacy: .public)")

        switch type {
        case .began:
            // Solo cuenta si otra app tomó el audio (no si iOS suspendió a Cue).
            guard reason == .default else { return }
            otherAppRecording = true
            guard isActive, settings.floatingAutoStart else { return }
            lastSignal = String(localized: "Recording detected")
            if !engine.isActive { engine.start() }
        case .ended:
            guard otherAppRecording else { return }
            otherAppRecording = false
            activateAudioSession()
            guard isActive, settings.floatingAutoStart else { return }
            lastSignal = String(localized: "Recording ended")
            if engine.isActive { engine.pause() }
        @unknown default:
            break
        }
    }

    // MARK: Ventana

    private func setUpController() {
        guard controller == nil else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer,
                                                                playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            log.notice("PiP possible=\(possible)")
            DispatchQueue.main.async { self?.possibleChanged(possible) }
        }
        self.controller = controller
    }

    private func possibleChanged(_ possible: Bool) {
        guard let controller, !controller.isPictureInPictureActive else { return }
        if possible {
            windowState = .ready
            if startWhenPossible {
                startWhenPossible = false
                controller.startPictureInPicture()
            }
        } else if case .failed = windowState {
            return
        } else {
            windowState = .preparing
        }
    }

    private func setUpTimebase() {
        guard displayLayer.controlTimebase == nil else { return }
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &timebase)
        guard let timebase else { return }
        CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
        CMTimebaseSetRate(timebase, rate: 1)
        displayLayer.controlTimebase = timebase
    }

    private func changeOrientation(vertical: Bool) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            renderer = Self.makeRenderer(vertical: vertical)
            lastState = nil
            displayLayer.sampleBufferRenderer.flush()
        }
    }

    private static func makeRenderer(vertical: Bool) -> PrompterFrameRenderer {
        vertical ? PrompterFrameRenderer(width: 720, height: 960) : PrompterFrameRenderer(width: 960, height: 720)
    }

    // MARK: Cuadros de video

    private func startFrames() {
        guard frameTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in self?.scheduleFrame() }
        timer.resume()
        frameTimer = timer
    }

    /// Toma el estado en el hilo principal y dibuja en la cola de dibujo.
    private func scheduleFrame() {
        let now = CACurrentMediaTime()
        var countdownFraction = 0.0
        if engine.isCountingDown {
            countdownFraction = min(1, now - engine.phaseChangedAt)
        }
        let state = PrompterFrameRenderer.State(
            text: engine.text,
            fontSize: CGFloat(settings.fontSize) * fontScale,
            centered: settings.centered,
            mirror: settings.mirror,
            progress: engine.progress(at: now),
            phase: engine.phase,
            countdownFraction: countdownFraction,
            elapsed: Int(engine.elapsed(at: now)),
            remaining: Int(engine.remaining(at: now).rounded(.up)),
            readyHint: settings.floatingAutoStart ? String(localized: "Waiting for you to record…") : String(localized: "Tap the window and press ▶")
        )
        renderQueue.async { [weak self] in self?.render(state, at: now) }
    }

    private func render(_ state: PrompterFrameRenderer.State, at now: CFTimeInterval) {
        // Sin cambios: un cuadro por segundo basta para mantener viva la ventana.
        if state == lastState && now - lastFrameTime < 1 { return }
        lastState = state
        lastFrameTime = now
        guard let sampleBuffer = renderer.makeSampleBuffer(state) else { return }
        let output = displayLayer.sampleBufferRenderer
        if output.status == .failed {
            output.flush()
        }
        output.enqueue(sampleBuffer)
    }
}

extension FloatingPrompter: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        log.notice("PiP will start")
        windowState = .open
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        log.notice("PiP did stop")
        windowState = controller.isPictureInPicturePossible ? .ready : .preparing
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        log.error("PiP failed: \(error.localizedDescription, privacy: .public)")
        windowState = .failed(String(localized: "Couldn't open: \(error.localizedDescription)"))
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

extension FloatingPrompter: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        log.notice("PiP setPlaying=\(playing)")
        DispatchQueue.main.async {
            playing ? self.engine.start() : self.engine.pause()
            controller.invalidatePlaybackState()
        }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        // Contenido "en vivo": la ventana muestra solo reproducir/pausa.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        !engine.isActive
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

/// Vista cuya capa es un `AVSampleBufferDisplayLayer` (lo que se ve en la ventana flotante).
final class SampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
