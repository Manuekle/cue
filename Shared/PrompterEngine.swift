import Foundation
import QuartzCore

/// Motor del prompter: cuenta regresiva, avance y pausa.
///
/// La posición se guarda como fracción del texto (0...1), así cada vista
/// (pantalla, ventana flotante, PiP) dibuja el mismo punto del guion sin
/// importar su tamaño. La velocidad está en palabras por minuto.
final class PrompterEngine: ObservableObject {
    enum Phase: Equatable {
        case ready
        case countdown(Int)
        case playing
        case paused
        case finished
    }

    @Published private(set) var phase: Phase = .ready {
        didSet { if phase != oldValue { phaseChangedAt = CACurrentMediaTime() } }
    }
    @Published private(set) var text = ""
    /// Cambia cada vez que la posición se mueve a mano (arrastre, reinicio).
    @Published private(set) var revision = 0

    private(set) var wordCount = 0
    /// Momento del último cambio de fase (para animar la cuenta regresiva).
    private(set) var phaseChangedAt = CACurrentMediaTime()
    var countdownSeconds = 3
    var wordsPerMinute: Double = 140 {
        willSet { reanchor() }
    }

    private var anchorTime = CACurrentMediaTime()
    private var anchorProgress = 0.0
    private var elapsedBase: TimeInterval = 0
    private var countdownTimer: Timer?
    private var endTimer: Timer?
    private var onBegin: (() -> Void)?

    var isPlaying: Bool { phase == .playing }

    /// Reproduciendo o en cuenta regresiva.
    var isActive: Bool {
        if case .countdown = phase { return true }
        return phase == .playing
    }

    var isCountingDown: Bool {
        if case .countdown = phase { return true }
        return false
    }

    private var rate: Double {
        guard wordCount > 0 else { return 0 }
        return wordsPerMinute / 60 / Double(wordCount)
    }

    // MARK: Lectura de estado

    func progress(at time: CFTimeInterval = CACurrentMediaTime()) -> Double {
        guard phase == .playing else { return anchorProgress }
        return min(1, anchorProgress + (time - anchorTime) * rate)
    }

    func elapsed(at time: CFTimeInterval = CACurrentMediaTime()) -> TimeInterval {
        guard phase == .playing else { return elapsedBase }
        return elapsedBase + (time - anchorTime)
    }

    func remaining(at time: CFTimeInterval = CACurrentMediaTime()) -> TimeInterval {
        guard wordsPerMinute > 0 else { return 0 }
        return (1 - progress(at: time)) * Double(wordCount) / wordsPerMinute * 60
    }

    // MARK: Control

    /// Carga un guion. Con `reset` vuelve al inicio; sin él conserva la posición.
    func load(text newText: String, reset: Bool) {
        if reset {
            stop()
        }
        guard newText != text else { return }
        reanchor()
        text = newText
        wordCount = Script.countWords(newText)
        if wordCount == 0 { stop() }
    }

    /// Arranca con cuenta regresiva (salvo `skipCountdown`). `onBegin` se llama justo
    /// cuando el texto empieza a moverse.
    func start(skipCountdown: Bool = false, onBegin: (() -> Void)? = nil) {
        guard wordCount > 0, !isActive else { return }
        if phase == .finished {
            anchorProgress = 0
            elapsedBase = 0
            revision += 1
        }
        self.onBegin = onBegin
        if countdownSeconds > 0 && !skipCountdown {
            phase = .countdown(countdownSeconds)
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.countdownTick() }
            RunLoop.main.add(timer, forMode: .common)
            countdownTimer = timer
        } else {
            begin()
        }
    }

    func pause() {
        switch phase {
        case .playing:
            reanchor()
            phase = .paused
        case .countdown:
            phase = anchorProgress > 0 ? .paused : .ready
        default:
            break
        }
        invalidateTimers()
        onBegin = nil
    }

    func togglePlay() {
        isActive ? pause() : start()
    }

    /// Vuelve al inicio y queda listo.
    func stop() {
        invalidateTimers()
        onBegin = nil
        anchorProgress = 0
        anchorTime = CACurrentMediaTime()
        elapsedBase = 0
        phase = .ready
        revision += 1
    }

    /// Alto del texto en la vista principal (lo pone `PrompterView`), para mover con la rueda/trackpad.
    var measuredHeight: Double = 0

    func scrub(points: Double) {
        guard measuredHeight > 0 else { return }
        scrub(by: points / measuredHeight)
    }

    func scrub(by delta: Double) {
        let target = (progress() + delta).clamped(to: 0...1)
        reanchor(to: target)
        if phase == .finished && target < 1 {
            phase = .paused
        } else if phase == .ready && target > 0 {
            phase = .paused
        }
        revision += 1
    }

    // MARK: Interno

    private func countdownTick() {
        guard case .countdown(let remaining) = phase else { return }
        if remaining > 1 {
            phase = .countdown(remaining - 1)
        } else {
            begin()
        }
    }

    private func begin() {
        invalidateTimers()
        anchorTime = CACurrentMediaTime()
        phase = .playing
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkEnd() }
        RunLoop.main.add(timer, forMode: .common)
        endTimer = timer
        let callback = onBegin
        onBegin = nil
        callback?()
    }

    private func checkEnd() {
        guard phase == .playing, progress() >= 1 else { return }
        reanchor(to: 1)
        phase = .finished
        invalidateTimers()
    }

    private func reanchor(to newProgress: Double? = nil) {
        let now = CACurrentMediaTime()
        let current = progress(at: now)
        if phase == .playing { elapsedBase += now - anchorTime }
        anchorProgress = newProgress ?? current
        anchorTime = now
    }

    private func invalidateTimers() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        endTimer?.invalidate()
        endTimer = nil
    }
}
