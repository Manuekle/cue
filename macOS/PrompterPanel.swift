import AppKit
import SwiftUI

/// Geometría del notch de la pantalla (nil si ningún Mac conectado tiene notch).
struct NotchInfo {
    let width: CGFloat
    let height: CGFloat
    let midX: CGFloat
    /// Borde superior de la pantalla (y en coordenadas globales).
    let top: CGFloat

    static var current: NotchInfo? {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { continue }
            return NotchInfo(width: right.minX - left.maxX, height: screen.safeAreaInsets.top,
                             midX: screen.frame.midX, top: screen.frame.maxY)
        }
        return nil
    }

    var rect: NSRect {
        NSRect(x: midX - width / 2, y: top - height, width: width, height: height)
    }
}

/// Pestaña flotante estilo notch/isla: sobre un Mac con notch, el prompter nace DENTRO del notch
/// (una píldora negra que lo ensancha) y al hacer clic crece hacia abajo; sin notch queda como una
/// pestaña pegada bajo la barra de menús. Siempre encima, también sobre apps en pantalla completa,
/// e invisible al compartir pantalla.
final class PrompterPanelController: NSObject, NSWindowDelegate {
    static let pillSize = NSSize(width: 250, height: 32)
    /// Ancho de cada "oreja" que asoma a los lados del notch cuando está contraído.
    static let earWidth: CGFloat = 60
    /// Curva cóncava a cada lado de la píldora, para que parezca salir del notch.
    static let pillShoulder: CGFloat = 6
    /// Lo mismo para el prompter expandido.
    static let panelShoulder: CGFloat = 12
    private static let minExpanded = NSSize(width: 440, height: 200)
    /// Separación entre el borde superior del prompter expandido y el de la píldora.
    private static let expandedGap: CGFloat = 6
    /// Sin marco del sistema: así la silueta (hombros, borde, esquinas) es la nuestra. El tamaño se cambia con el asa propia.
    private static let panelStyle: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
    /// Margen transparente alrededor de la silueta anclada al notch, para que quepa la sombra.
    /// Arriba no hay: el panel nace del borde de la pantalla.
    static let shadowMargin = (side: CGFloat(14), bottom: CGFloat(18))
    private static let frameKey = "PronterExpandedFrame"
    private static let sizeKey = "PronterNotchExpandedSize"

    /// Animación de la silueta anclada al notch: abre con un rebote leve, cierra sin rebote.
    static let openAnimation = Animation.spring(duration: 0.42, bounce: 0.15)
    static let closeAnimation = Animation.spring(duration: 0.32, bounce: 0)

    private unowned let model: MacAppModel
    private var panel: PrompterPanel?
    private var eventMonitor: Any?
    private var notchMonitor: Any?
    /// Mientras la ventana ignora el ratón (puntero en el margen de la sombra) no recibe eventos:
    /// este temporizador vigila el puntero hasta que vuelve a la silueta o sale de la ventana.
    private var passthroughTimer: Timer?
    private var isExpanded = true
    private var isApplyingFrame = false
    /// Cada cierre animado tiene su número; al terminar solo encoge la ventana si nadie lo interrumpió.
    private var collapseGeneration = 0
    /// Posición y tamaño del prompter expandido; la píldora se ancla a su borde superior.
    private var expandedFrame: NSRect
    /// Estado que dibuja SwiftUI cuando el panel está anclado al notch.
    let docked: NotchPanelState
    /// Tamaño del prompter expandido cuando está anclado al notch (incluye la franja del notch).
    private var dockedSize: NSSize {
        get { docked.size }
        set { docked.size = newValue }
    }
    /// Frame al empezar a arrastrar el asa de tamaño.
    private var resizeStartFrame: NSRect?

    init(model: MacAppModel) {
        self.model = model
        let inset = NotchInfo.current?.height ?? 0
        var size = NSSize(width: 600, height: 300 + inset)
        if let saved = UserDefaults.standard.string(forKey: Self.sizeKey) {
            let rect = NSRectFromString(saved)
            if rect.width >= Self.minExpanded.width, rect.height >= Self.minExpanded.height + inset { size = rect.size }
        }
        docked = NotchPanelState(size: size)
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let rect = NSRectFromString(saved)
            if rect.width >= Self.minExpanded.width, rect.height >= Self.minExpanded.height,
               NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) {
                expandedFrame = rect
                super.init()
                return
            }
        }
        expandedFrame = Self.defaultFrame()
        super.init()
    }

    /// Frame del prompter expandido (anclado al notch si lo hay).
    private var resolvedExpandedFrame: NSRect {
        guard let notch = NotchInfo.current else { return expandedFrame }
        return Self.withShadowMargin(NSRect(x: notch.midX - dockedSize.width / 2, y: notch.top - dockedSize.height,
                                            width: dockedSize.width, height: dockedSize.height))
    }

    /// Ancho de la píldora contraída: notch + orejas + hombros.
    static func pillWidth(notchWidth: CGFloat) -> CGFloat {
        notchWidth + earWidth * 2 + pillShoulder * 2
    }

    /// La silueta que se ve ahora (o hacia la que se anima), en coordenadas de pantalla. nil sin notch.
    private var silhouette: NSRect? {
        guard let notch = NotchInfo.current else { return nil }
        let size = isExpanded ? dockedSize : NSSize(width: Self.pillWidth(notchWidth: notch.width), height: notch.height)
        return NSRect(x: notch.midX - size.width / 2, y: notch.top - size.height, width: size.width, height: size.height)
    }

    private var collapsedFrame: NSRect {
        if let notch = NotchInfo.current {
            let width = Self.pillWidth(notchWidth: notch.width)
            return Self.withShadowMargin(NSRect(x: notch.midX - width / 2, y: notch.top - notch.height,
                                                width: width, height: notch.height))
        }
        let size = Self.pillSize
        return NSRect(x: expandedFrame.midX - size.width / 2,
                      y: expandedFrame.maxY + Self.expandedGap - size.height,
                      width: size.width, height: size.height)
    }

    /// Ventana = silueta + margen para la sombra a los lados y abajo.
    private static func withShadowMargin(_ rect: NSRect) -> NSRect {
        NSRect(x: rect.minX - shadowMargin.side, y: rect.minY - shadowMargin.bottom,
               width: rect.width + shadowMargin.side * 2, height: rect.height + shadowMargin.bottom)
    }

    /// La silueta visible dentro de la ventana (sin el margen de la sombra).
    private static func visibleRect(of frame: NSRect) -> NSRect {
        guard NotchInfo.current != nil else { return frame }
        return NSRect(x: frame.minX + shadowMargin.side, y: frame.minY + shadowMargin.bottom,
                      width: frame.width - shadowMargin.side * 2, height: frame.height - shadowMargin.bottom)
    }

    // MARK: Mostrar / ocultar

    func show(expanded: Bool) {
        if let panel, panel.isVisible {
            setExpanded(expanded)
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        isExpanded = expanded
        apply(to: panel, animated: false)
        panel.orderFrontRegardless()
        installEventMonitor()
        installNotchMonitor()
    }

    /// `animated`: se desvanece en vez de desaparecer de golpe (al cerrar sin pestaña en el notch).
    func hide(animated: Bool = false) {
        stopPassthroughTimer()
        guard let panel, panel.isVisible else { return }
        guard animated else { return panel.orderOut(nil) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // Si mientras tanto se volvió a mostrar, no ocultarlo.
            if self?.model.isPanelVisible == false { panel.orderOut(nil) }
            panel.alphaValue = 1
        }
    }

    /// Anima entre píldora y prompter completo.
    func setExpanded(_ expanded: Bool) {
        guard let panel, panel.isVisible, expanded != isExpanded else { return }
        isExpanded = expanded
        apply(to: panel, animated: true)
    }

    private func apply(to panel: PrompterPanel, animated: Bool) {
        let notch = NotchInfo.current
        // Con notch, la ventana va por encima de la barra de menús para fundirse con él.
        panel.level = notch != nil ? NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1) : .floating
        panel.styleMask = Self.panelStyle
        panel.minSize = NSSize(width: 1, height: 1)
        // Pegado al notch, la sombra la dibuja SwiftUI (suave, solo hacia abajo); la del sistema marcaría un contorno.
        panel.hasShadow = notch == nil
        collapseGeneration += 1
        guard notch != nil else {
            isApplyingFrame = true
            panel.setFrame(isExpanded ? resolvedExpandedFrame : collapsedFrame, display: true, animate: animated)
            isApplyingFrame = false
            updatePassthrough()
            return
        }
        // Anclado: la ventana no se anima (setFrame animado bloquea el hilo y deforma el contenido).
        // Mide lo del panel abierto mientras haga falta y SwiftUI anima la silueta dentro de ella.
        if isExpanded {
            setFrame(resolvedExpandedFrame, on: panel)
            setDockedExpanded(true, animated: animated)
        } else if animated {
            // La ventana sigue grande hasta que la silueta termina de encogerse; luego se ajusta a la píldora.
            let generation = collapseGeneration
            setDockedExpanded(false, animated: true) { [weak self] in
                guard let self, let panel = self.panel, !self.isExpanded, generation == self.collapseGeneration else { return }
                self.setFrame(self.collapsedFrame, on: panel)
                self.updatePassthrough()
            }
        } else {
            setDockedExpanded(false, animated: false)
            setFrame(collapsedFrame, on: panel)
        }
        updatePassthrough()
    }

    private func setFrame(_ frame: NSRect, on panel: PrompterPanel) {
        guard panel.frame != frame else { return }
        isApplyingFrame = true
        panel.setFrame(frame, display: true)
        // Que SwiftUI recoloque ya, sin animación, lo que hay dentro (va centrado en la ventana). Si no, la
        // animación que sigue partiría de la posición vieja en la ventana nueva y la silueta llegaría de lado.
        panel.contentView?.layoutSubtreeIfNeeded()
        isApplyingFrame = false
    }

    private func setDockedExpanded(_ expanded: Bool, animated: Bool, completion: (() -> Void)? = nil) {
        guard animated else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { docked.expanded = expanded }
            completion?()
            return
        }
        withAnimation(expanded ? Self.openAnimation : Self.closeAnimation, completionCriteria: .logicallyComplete) {
            docked.expanded = expanded
        } completion: {
            completion?()
        }
    }

    // MARK: Tamaño (bordes invisibles)

    func beginResize() {
        resizeStartFrame = panel?.frame
    }

    /// Borde del panel que se arrastra para cambiar el tamaño.
    enum ResizeEdge {
        case left, right, bottom, bottomLeft, bottomRight

        /// -1 = el lado izquierdo (arrastrar a la izquierda agranda), 1 = el derecho, 0 = ninguno.
        var horizontal: CGFloat {
            switch self {
            case .left, .bottomLeft: -1
            case .right, .bottomRight: 1
            case .bottom: 0
            }
        }

        var vertical: Bool { self != .left && self != .right }

        var cursor: NSCursor {
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition = switch self {
                case .left: .left
                case .right: .right
                case .bottom: .bottom
                case .bottomLeft: .bottomLeft
                case .bottomRight: .bottomRight
                }
                return .frameResize(position: position, directions: .all)
            }
            return vertical && horizontal == 0 ? .resizeUpDown : (vertical ? .crosshair : .resizeLeftRight)
        }
    }

    /// `translation` en puntos desde que empezó el arrastre (y hacia abajo, como en SwiftUI).
    func resize(translation: CGSize, edge: ResizeEdge) {
        guard let panel, let start = resizeStartFrame, isExpanded else { return }
        let notch = NotchInfo.current
        let minHeight = Self.minExpanded.height + (notch?.height ?? 0)
        let maxWidth = (panel.screen ?? NSScreen.main)?.frame.width ?? 1600
        let dx = translation.width * edge.horizontal
        let dy = edge.vertical ? translation.height : 0
        if notch != nil {
            // Anclado: crece simétrico alrededor del notch y solo hacia abajo.
            let visible = Self.visibleRect(of: start)
            dockedSize = NSSize(width: (visible.width + dx * 2).clamped(to: Self.minExpanded.width...maxWidth),
                                height: max(minHeight, visible.height + dy))
            isApplyingFrame = true
            panel.setFrame(resolvedExpandedFrame, display: true)
            isApplyingFrame = false
        } else {
            let width = (start.width + dx).clamped(to: Self.minExpanded.width...maxWidth)
            let height = max(minHeight, start.height + dy)
            let x = edge.horizontal < 0 ? start.maxX - width : start.minX
            panel.setFrame(NSRect(x: x, y: start.maxY - height, width: width, height: height), display: true)
        }
    }

    func endResize() {
        resizeStartFrame = nil
        updatePassthrough()
        guard let panel, isExpanded else { return }
        if NotchInfo.current != nil {
            UserDefaults.standard.set(NSStringFromRect(NSRect(origin: .zero, size: dockedSize)), forKey: Self.sizeKey)
        } else {
            rememberFrame()
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        model.panelDidClose()
    }

    func windowDidMove(_ notification: Notification) { rememberFrame() }
    func windowDidResize(_ notification: Notification) { rememberFrame() }

    private func rememberFrame() {
        guard NotchInfo.current == nil, isExpanded, !isApplyingFrame, let panel else { return }
        expandedFrame = panel.frame
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    // MARK: Construcción

    private func makePanel() -> PrompterPanel {
        let panel = PrompterPanel(contentRect: resolvedExpandedFrame,
                                  styleMask: Self.panelStyle,
                                  backing: .buffered, defer: false)
        panel.title = "Cue"
        panel.level = .floating
        // stationary: al hacer clic en el fondo de pantalla (mostrar escritorio) o en Mission Control, macOS
        // aparta todas las ventanas; sin esto el panel se desliza hacia abajo y desaparece del notch.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        // Invisible al compartir pantalla o grabar (Meet, Zoom, QuickTime…): solo tú lo ves.
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        let hosting = NSHostingView(rootView: PrompterPanelRoot(model: model,
                                                               engine: model.engine,
                                                               settings: model.settings,
                                                               monitor: model.monitor,
                                                               store: model.store,
                                                               docked: docked))
        hosting.sizingOptions = []   // el tamaño lo decide el controlador, no el contenido
        let container = PointerTrackingView()
        container.onPointerChange = { [weak self] in self?.updatePassthrough() }
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        return panel
    }

    /// Arriba al centro de la pantalla, justo debajo del notch / barra de menús.
    private static func defaultFrame() -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(720, visible.width * 0.55)
        let height: CGFloat = 300
        return NSRect(x: visible.midX - width / 2, y: visible.maxY - height - expandedGap, width: width, height: height)
    }

    // MARK: Entrada

    /// Teclado y rueda/trackpad cuando el panel está al frente.
    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self, let panel, event.window === panel, isExpanded else { return event }
            // En modo Copiloto el teclado y la rueda son para la sugerencia, no para el guion.
            if model.panelMode == .copilot { return event }
            if event.type == .scrollWheel {
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
                model.engine.scrub(points: -Double(delta))
                return nil
            }
            return handleKey(event) ? nil : event
        }
    }

    /// Clic en el notch (desde cualquier app) = mostrar / contraer el prompter. Se instala al arrancar,
    /// también con la pestaña oculta, para que el notch siga abriendo el prompter.
    func installNotchMonitor() {
        guard notchMonitor == nil else { return }
        notchMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self, Self.isNotchClick(NSEvent.mouseLocation) else { return }
            DispatchQueue.main.async { self.model.togglePrompter() }
        }
    }

    /// La ventana anclada es más grande que la silueta (por la sombra, y mientras se anima el cierre).
    /// Solo ignora el ratón con el puntero dentro de la ventana pero fuera de la silueta, para que esos
    /// clics lleguen a la app de debajo. Fuera de la ventana vuelve a aceptarlo (no tapa nada), así que
    /// un evento perdido nunca deja el notch sin responder.
    ///
    /// Mientras acepta el ratón, un área de seguimiento de la propia ventana avisa de cada movimiento
    /// (también con Pronter delante, cuando un monitor global no recibe nada). Mientras lo ignora, la
    /// ventana no recibe eventos y lo vigila `passthroughTimer`.
    private func updatePassthrough() {
        guard let panel, panel.isVisible else { return stopPassthroughTimer() }
        let mouse = NSEvent.mouseLocation
        // Durante el arrastre del asa el puntero puede salir de la silueta: no soltar el ratón a mitad.
        let inShape = resizeStartFrame != nil || (silhouette ?? panel.frame).contains(mouse)
        let ignore = panel.frame.contains(mouse) && !inShape
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
        if ignore { startPassthroughTimer() } else { stopPassthroughTimer() }
    }

    private func startPassthroughTimer() {
        guard passthroughTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.updatePassthrough() }
        timer.tolerance = 0.004
        RunLoop.main.add(timer, forMode: .common)
        passthroughTimer = timer
    }

    private func stopPassthroughTimer() {
        passthroughTimer?.invalidate()
        passthroughTimer = nil
    }

    private static func isNotchClick(_ point: NSPoint) -> Bool {
        guard let notch = NotchInfo.current else { return false }
        return notch.rect.contains(point)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49: model.engine.togglePlay()                 // espacio
        case 126: model.settings.adjustSpeed(by: 10)      // ↑
        case 125: model.settings.adjustSpeed(by: -10)     // ↓
        case 53: model.collapsePrompter()                 // esc
        case 123: model.selectAdjacentScript(-1)          // ←
        case 124: model.selectAdjacentScript(1)           // →
        default:
            switch event.charactersIgnoringModifiers {
            case "+", "=": model.settings.adjustFont(by: 2)
            case "-": model.settings.adjustFont(by: -2)
            case "r", "R": model.engine.stop()
            case "m", "M": model.settings.mirror.toggle()
            case let key? where key.count == 1 && ("1"..."9").contains(key):
                model.selectScript(at: Int(key)! - 1)
            default: return false
            }
        }
        return true
    }
}

final class PrompterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Evita que macOS empuje la ventana por debajo de la barra de menús (necesario para vivir en el notch).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Lo que SwiftUI necesita para dibujar el panel anclado al notch. Lo cambia el controlador
/// (`expanded` dentro de una animación), así la silueta se anima sin tocar el frame de la ventana.
final class NotchPanelState: ObservableObject {
    @Published var expanded = true
    /// Tamaño de la silueta abierta (incluye la franja del notch), sin el margen de la sombra.
    @Published var size: NSSize

    init(size: NSSize) {
        self.size = size
    }
}

/// Vista raíz de la ventana: avisa de cada movimiento del puntero dentro de ella, esté o no
/// Pronter delante (`.activeAlways`), para decidir si los clics pasan a la app de debajo.
final class PointerTrackingView: NSView {
    var onPointerChange: (() -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseMoved(with event: NSEvent) { onPointerChange?() }
    override func mouseEntered(with event: NSEvent) { onPointerChange?() }
    override func mouseExited(with event: NSEvent) { onPointerChange?() }
}

/// Elige entre la píldora y el prompter completo.
struct PrompterPanelRoot: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var engine: PrompterEngine
    @ObservedObject var settings: PrompterSettings
    @ObservedObject var monitor: RecordingMonitor
    @ObservedObject var store: ScriptStore
    let docked: NotchPanelState

    var body: some View {
        Group {
            if let notch = NotchInfo.current {
                DockedNotchView(model: model, engine: engine, settings: settings, monitor: monitor, store: store,
                                state: docked, notch: notch)
            } else if model.isPanelExpanded {
                MacPrompterPanelView(model: model, engine: engine, settings: settings, monitor: monitor,
                                     copilot: model.copilot)
            } else {
                MacPillView(model: model, engine: engine, store: store, copilot: model.copilot)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .font(.display(13))
    }
}

/// Panel anclado al notch: una sola silueta negra que se anima entre la píldora y el prompter abierto.
/// La ventana no cambia de tamaño durante la animación (mide lo del panel abierto); aquí cambia el
/// tamaño de la silueta, que va arriba al centro, pegada al notch. El contenido de cada estado tiene
/// tamaño fijo y la silueta lo recorta: el texto no se recoloca en cada fotograma.
private struct DockedNotchView: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var engine: PrompterEngine
    @ObservedObject var settings: PrompterSettings
    @ObservedObject var monitor: RecordingMonitor
    @ObservedObject var store: ScriptStore
    @ObservedObject var state: NotchPanelState
    let notch: NotchInfo
    @State private var pillHover = false

    /// Al pasar el ratón la píldora crece un poco, para que se note que se puede hacer clic.
    private static let hoverGrowth = CGSize(width: 8, height: 3)
    private static let pillRadius: CGFloat = 12
    static let panelRadius: CGFloat = 26

    private var pillSize: CGSize {
        CGSize(width: PrompterPanelController.pillWidth(notchWidth: notch.width), height: notch.height)
    }

    var body: some View {
        let expanded = state.expanded
        let full = CGSize(width: state.size.width, height: state.size.height)
        let pill = pillSize
        let size = expanded ? full
            : pillHover ? CGSize(width: pill.width + Self.hoverGrowth.width, height: pill.height + Self.hoverGrowth.height)
            : pill
        let shape = NotchShape(shoulder: expanded ? PrompterPanelController.panelShoulder : PrompterPanelController.pillShoulder,
                               bottomRadius: expanded ? Self.panelRadius : Self.pillRadius)

        ZStack(alignment: .top) {
            if expanded {
                MacPrompterPanelView(model: model, engine: engine, settings: settings, monitor: monitor,
                                     copilot: model.copilot, topInset: notch.height, notchWidth: notch.width)
                    .frame(width: full.width, height: full.height)
                    // Una sola capa: sin esto el ModeSwitch (matchedGeometryEffect) se pinta fuera del recorte al cerrar.
                    .compositingGroup()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                            .animation(.easeOut(duration: 0.24).delay(0.07)),
                        removal: .opacity.animation(.easeIn(duration: 0.1))))
            } else {
                MacNotchPillView(model: model, engine: engine, store: store, copilot: model.copilot, notchWidth: notch.width)
                    .frame(width: pill.width, height: pill.height)
                    .onHover { pillHover = $0 }
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.12)),
                        removal: .opacity.animation(.easeIn(duration: 0.08))))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(alignment: .top) { background(expanded: expanded) }
        .clipShape(shape)
        .background { OuterShadow(shape: shape) }
        .animation(.spring(duration: 0.25, bounce: 0.3), value: pillHover)
        .onChange(of: expanded) { pillHover = false }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Cerrado: negro puro, como el notch. Abierto: vidrio oscuro (desenfoque de lo de detrás + negro
    /// translúcido), con negro puro arriba para que siga pareciendo una extensión del notch.
    private func background(expanded: Bool) -> some View {
        let tint = expanded ? PanelStyle.glassTint : 1
        return ZStack(alignment: .top) {
            if expanded {
                ShapedBlur(shape: AnyShape(NotchShape(shoulder: PrompterPanelController.panelShoulder,
                                                      bottomRadius: Self.panelRadius)))
                    .transition(.opacity)
            }
            VStack(spacing: 0) {
                PanelStyle.fill.frame(height: notch.height)
                LinearGradient(colors: [PanelStyle.fill, PanelStyle.fill.opacity(tint)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 36)
                PanelStyle.fill.opacity(tint)
            }
        }
    }
}

// MARK: Forma y borde

/// Silueta anclada al borde superior de la pantalla: arriba recta a todo lo ancho, con "hombros"
/// cóncavos (como si saliera del notch) y esquinas redondeadas abajo.
struct NotchShape: Shape {
    var shoulder: CGFloat
    var bottomRadius: CGFloat
    /// `false` = solo el contorno visible (lados y base), para dibujar el borde sin la línea de arriba.
    var closed = true
    /// Sube la base este tanto, para que el trazo del borde no se corte en el borde de la ventana.
    var bottomInset: CGFloat = 0

    /// Hombros y radio se animan junto con el tamaño al pasar de píldora a panel.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottomRadius) }
        set { shoulder = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let maxY = rect.maxY - bottomInset
        let s = min(shoulder, rect.width / 4)
        let b = min(bottomRadius, (maxY - rect.minY - s) / 2, (rect.width - 2 * s) / 2)
        let left = rect.minX + s, right = rect.maxX - s
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: left, y: rect.minY + s), radius: s)
        path.addArc(tangent1End: CGPoint(x: left, y: maxY), tangent2End: CGPoint(x: left + b, y: maxY), radius: b)
        path.addArc(tangent1End: CGPoint(x: right, y: maxY), tangent2End: CGPoint(x: right, y: maxY - b), radius: b)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: s)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        if closed { path.closeSubpath() }
        return path
    }
}

/// Negro puro para fundirse con el notch, sin borde, con una sombra pequeña.
private enum PanelStyle {
    static let fill = Color.black
    /// Opacidad del negro sobre el vidrio del panel abierto (lo de detrás se ve desenfocado y oscuro).
    static let glassTint = 0.58
    static let shadow = Color.black.opacity(0.35)
    /// Sombra "sm": cabe de sobra en `PrompterPanelController.shadowMargin` (no se corta).
    static let shadowRadius: CGFloat = 4
    static let shadowY: CGFloat = 2
}

// MARK: Vidrio

/// Vidrio: desenfoque real de lo que hay detrás de la ventana, recortado con la silueta del panel.
/// La silueta va como `maskImage` (un recorte de SwiftUI no siempre limita el desenfoque del sistema).
struct ShapedBlur: NSViewRepresentable {
    let shape: AnyShape

    func makeNSView(context: Context) -> BlurView {
        let view = BlurView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.shape = shape
        return view
    }

    func updateNSView(_ view: BlurView, context: Context) {
        view.shape = shape
    }

    final class BlurView: NSVisualEffectView {
        var shape: AnyShape? {
            didSet { maskSize = .zero; needsLayout = true }
        }
        private var maskSize: CGSize = .zero

        override func layout() {
            super.layout()
            guard let shape, bounds.width > 0, bounds.height > 0, bounds.size != maskSize else { return }
            maskSize = bounds.size
            let path = shape.path(in: CGRect(origin: .zero, size: bounds.size)).cgPath
            maskImage = NSImage(size: bounds.size, flipped: true) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.addPath(path)
                context.setFillColor(.black)
                context.fillPath()
                return true
            }
        }
    }
}

/// Sombra pequeña solo por fuera de la silueta, para que no oscurezca el vidrio por dentro.
private struct OuterShadow<S: Shape>: View {
    let shape: S

    var body: some View {
        shape.fill(Color.black)
            .shadow(color: PanelStyle.shadow, radius: PanelStyle.shadowRadius, y: PanelStyle.shadowY)
            .mask {
                ZStack {
                    Rectangle().padding(-40)
                    shape.blendMode(.destinationOut)
                }
                .compositingGroup()
            }
    }
}

// MARK: Atajos y reloj

/// Tecla de atajo estilo teclado. Los modificadores van con íconos (las fuentes de la app no traen ⌃⌥⌘↩).
struct Keycap: View {
    enum Key {
        case control, option, command, returnKey
        case letter(String)
    }

    let key: Key

    var body: some View {
        label
            .foregroundStyle(.white.opacity(0.78))
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }

    @ViewBuilder private var label: some View {
        switch key {
        case .control: HugeIcon(.control, size: 11)
        case .option: HugeIcon(.option, size: 11)
        case .command: HugeIcon(.command, size: 11)
        case .returnKey: HugeIcon(.returnKey, size: 11)
        case .letter(let text):
            Text(text)
                .font(.mono(10.5, .medium))
                .padding(.horizontal, 5)
        }
    }
}

/// Varias teclas seguidas: ⌃ ⌥ ↩.
struct KeyCombo: View {
    let keys: [Keycap.Key]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys.indices, id: \.self) { Keycap(key: keys[$0]) }
        }
    }
}

/// Acción de la barra con su atajo, estilo "Preguntar ⌃⌥↩".
private struct ToolbarAction: View {
    let title: LocalizedStringKey
    let keys: [Keycap.Key]
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.display(12.5, .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                KeyCombo(keys: keys)
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .fixedSize()
    }
}

/// Reloj mm:ss en Geist Mono.
private func timerText(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d", total / 60, total % 60)
}

/// Tiempo escuchando (00:00 en pausa).
struct ListeningClock: View {
    let since: Date?
    var size: CGFloat = 12.5

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(timerText(since.map { context.date.timeIntervalSince($0) } ?? 0))
                .font(.mono(size, .medium))
                .foregroundStyle(.white.opacity(since == nil ? 0.4 : 0.88))
                .fixedSize()
        }
    }
}

/// Micrófono redondo: empezar / dejar de escuchar.
private struct MicButton: View {
    @ObservedObject var copilot: CopilotModel

    var body: some View {
        let listening = copilot.isListening
        Button { copilot.toggleListening() } label: {
            ZStack {
                Circle().fill(listening ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.12)))
                if copilot.isBusy && !listening {
                    ProgressView().controlSize(.mini)
                } else {
                    HugeIcon(.mic, size: 14, filled: true)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(listening ? "Stop listening (⌃⌥L)" : "Listen (⌃⌥L)")
    }
}

/// Menú ⋮ del panel.
private struct PanelMenu: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var copilot: CopilotModel

    var body: some View {
        Menu {
            if model.panelMode == .copilot {
                Button("Copy suggestion") { copilot.copySuggestion() }
                    .disabled(copilot.suggestion.isEmpty)
                Button("Clear conversation") { copilot.clearConversation() }
                Divider()
            }
            pillMenu(model)
        } label: {
            HugeIcon(.more, size: 16)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(.white.opacity(0.7))
        .fixedSize()
        .help("More options")
    }
}

// MARK: Píldoras

private struct PillTitle: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var store: ScriptStore

    var body: some View {
        Text(title)
            .font(.display(12, .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
    }

    private var title: String {
        if model.panelMode == .copilot { return String(localized: "Copilot") }
        return model.selectedScript?.displayTitle ?? "Cue"
    }
}

/// Reproducir (o escuchar, en modo Copiloto) desde la píldora.
private struct PillAction: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var engine: PrompterEngine
    @ObservedObject var copilot: CopilotModel

    var body: some View {
        let copilotMode = model.panelMode == .copilot
        let icon: HugeIcon.Name = copilotMode ? (copilot.isBusy ? .stop : .mic) : (engine.isActive ? .pause : .play)
        let active = copilotMode ? copilot.isBusy : engine.isActive
        Button {
            if copilotMode { copilot.toggleListening() } else { model.togglePlay() }
        } label: {
            HugeIcon(icon, size: 11, filled: true)
                .foregroundStyle(active ? Color.white : .black)
                .frame(width: 20, height: 20)
                .background(Circle().fill(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.pearl)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .disabled(!copilotMode && model.selectedScript?.wordCount ?? 0 == 0)
        .help(copilotMode ? "Listen / stop (⌃⌥L)" : "Play / pause (⌃⌥ space)")
    }
}

/// Tiempo en la píldora, solo mientras pasa algo.
private struct PillClock: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var engine: PrompterEngine
    @ObservedObject var copilot: CopilotModel

    var body: some View {
        if model.panelMode == .copilot {
            if let since = copilot.listeningSince {
                ListeningClock(since: since, size: 11)
            }
        } else if engine.isActive {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(timerText(engine.elapsed()))
                    .font(.mono(11, .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize()
            }
        }
    }
}

private struct PillStatusDot: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var engine: PrompterEngine
    @ObservedObject var copilot: CopilotModel

    var body: some View {
        if model.panelMode == .copilot {
            LiveDot(active: copilot.isListening, size: 6)
                .frame(width: 12, height: 12)
        } else {
            Circle()
                .fill(engine.isActive ? Theme.record : Color.white.opacity(0.3))
                .frame(width: 6, height: 6)
                .shadow(color: engine.isActive ? Theme.record.opacity(0.8) : .clear, radius: 4)
                .frame(width: 12, height: 12)
        }
    }
}

/// Contenido de la píldora contraída sobre un Mac con notch (la banda negra y la sombra las dibuja
/// `DockedNotchView`). Clic en cualquier punto, también en el notch = abrir el prompter.
struct MacNotchPillView: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var engine: PrompterEngine
    @ObservedObject var store: ScriptStore
    @ObservedObject var copilot: CopilotModel
    let notchWidth: CGFloat

    private let shoulder = PrompterPanelController.pillShoulder

    var body: some View {
        let shape = NotchShape(shoulder: shoulder, bottomRadius: 12)
        // Compacta, como una isla: a la izquierda el estado (y el tiempo si algo corre), a la derecha la acción.
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                PillStatusDot(model: model, engine: engine, copilot: copilot)
                PillClock(model: model, engine: engine, copilot: copilot)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .frame(width: PrompterPanelController.earWidth)

            Color.clear.frame(width: notchWidth)

            HStack {
                Spacer(minLength: 0)
                PillAction(model: model, engine: engine, copilot: copilot)
            }
            .padding(.trailing, 8)
            .frame(width: PrompterPanelController.earWidth)
        }
        .padding(.horizontal, shoulder)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .contentShape(shape)
        .onTapGesture { model.expandPrompter() }
        .contextMenu { pillMenu(model) }
        .help(pillHelp)
    }
}

extension MacNotchPillView {
    /// El título ya no cabe en la píldora: va en la ayuda al pasar el ratón.
    fileprivate var pillHelp: String {
        let title = model.panelMode == .copilot ? String(localized: "Copilot") : (model.selectedScript?.displayTitle ?? "Cue")
        return String(localized: "\(title) · click the notch to open")
    }
}

/// Píldora contraída sin notch: pegada bajo la barra de menús.
struct MacPillView: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var engine: PrompterEngine
    @ObservedObject var store: ScriptStore
    @ObservedObject var copilot: CopilotModel
    @State private var hovering = false

    var body: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14, style: .continuous)
        HStack(spacing: 8) {
            PillStatusDot(model: model, engine: engine, copilot: copilot)
            PillTitle(model: model, store: store)
            Spacer(minLength: 4)
            PillClock(model: model, engine: engine, copilot: copilot)
            PillAction(model: model, engine: engine, copilot: copilot)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(PanelStyle.fill))
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.expandPrompter() }
        .contextMenu { pillMenu(model) }
        .help("Click to open the prompter")
    }
}

/// Menú para cambiar de guion desde el panel (también ⌃⌥← / ⌃⌥→ y ⌥⌘1–9).
private struct ScriptPicker: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var store: ScriptStore

    var body: some View {
        Menu {
            ScriptMenuItems(model: model, store: store)
        } label: {
            // En macOS el menú aplana la etiqueta (una imagen iría delante del texto): la flecha la pone el sistema.
            Text(model.selectedScript?.displayTitle ?? String(localized: "Choose script"))
                .font(.display(12.5, .semibold))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .foregroundStyle(.white.opacity(0.8))
        .frame(maxWidth: 200, alignment: .leading)
        .fixedSize()
        .help("Switch script (⌃⌥← / ⌃⌥→)")
    }
}

/// Lista de guiones con su atajo, para los menús.
private struct ScriptMenuItems: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var store: ScriptStore

    var body: some View {
        ForEach(store.visibleScripts) { script in
            Button {
                model.chooseScript(script.id)
            } label: {
                if script.id == model.selectedID {
                    Label(script.displayTitle, systemImage: "checkmark")
                } else {
                    Text(script.displayTitle)
                }
            }
        }
    }
}

@ViewBuilder
private func pillMenu(_ model: MacAppModel) -> some View {
    Menu("Script") { ScriptMenuItems(model: model, store: model.store) }
    Divider()
    Button("Show script") { model.panelMode = .script; model.expandPrompter() }
    Button("Show Copilot") { model.showCopilot() }
    Divider()
    Button("Hide tab") { model.hideTab() }
}

// MARK: Panel expandido

/// Prompter abierto: guion o Copiloto. Clic en el notch (la franja de arriba) lo vuelve a cerrar.
struct MacPrompterPanelView: View {
    @ObservedObject var model: MacAppModel
    @ObservedObject var engine: PrompterEngine
    @ObservedObject var settings: PrompterSettings
    @ObservedObject var monitor: RecordingMonitor
    @ObservedObject var copilot: CopilotModel
    /// Altura del notch cuando el prompter está anclado a él (el contenido empieza debajo). 0 = sin notch.
    var topInset: CGFloat = 0
    /// Ancho del notch: solo esa zona (más las orejas de la píldora) de la franja de arriba cierra el panel.
    var notchWidth: CGFloat = 0
    @State private var hovering = false

    private var docked: Bool { topInset > 0 }
    private var shoulder: CGFloat { docked ? PrompterPanelController.panelShoulder : 0 }
    private static let floatingRadius: CGFloat = 22

    /// Anclado, la silueta (fondo, recorte y sombra) la dibuja `DockedNotchView` para poder animarla.
    private var panelShape: AnyShape {
        docked
            ? AnyShape(NotchShape(shoulder: shoulder, bottomRadius: DockedNotchView.panelRadius))
            : AnyShape(RoundedRectangle(cornerRadius: Self.floatingRadius, style: .continuous))
    }

    private var isCopilot: Bool { model.panelMode == .copilot }
    private var showsControls: Bool { hovering || !engine.isActive }
    private var highlighted: Bool { isCopilot ? copilot.isListening : engine.isActive }

    var body: some View {
        ZStack {
            if !docked { background }

            VStack(spacing: 0) {
                notchStrip
                header
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, shoulder)

            if !isCopilot {
                VStack {
                    Spacer(minLength: 0)
                    footer
                        .opacity(showsControls ? 1 : 0)
                }
                .padding(.horizontal, shoulder)
            }
        }
        .clipShape(panelShape)
        .overlay { ResizeEdges(model: model, inset: shoulder, top: topInset + 12) }
        .ignoresSafeArea()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: showsControls)
        .animation(.easeOut(duration: 0.2), value: hovering)
        .animation(.easeInOut(duration: 0.3), value: highlighted)
        .animation(.easeInOut(duration: 0.25), value: model.panelMode)
    }

    // MARK: Partes

    /// Vidrio oscuro del panel flotante (sin notch): desenfoque de lo de detrás + negro translúcido.
    private var background: some View {
        ZStack {
            ShapedBlur(shape: panelShape)
            PanelStyle.fill.opacity(PanelStyle.glassTint)
        }
    }

    /// La franja del notch. Solo la zona del notch y de las orejas de la píldora (donde se hizo clic para
    /// abrir) cierra el prompter; el resto de la franja es parte del panel y no hace nada.
    /// Sin notch, sirve para arrastrar la ventana.
    @ViewBuilder private var notchStrip: some View {
        if docked {
            Color.clear
                .frame(height: topInset)
                .overlay {
                    Color.clear
                        .frame(width: PrompterPanelController.pillWidth(notchWidth: notchWidth))
                        .contentShape(Rectangle())
                        .onTapGesture { model.collapsePrompter() }
                        .help("Click the notch to close")
                }
        } else {
            WindowDragArea()
                .frame(height: 10)
        }
    }

    /// Barra de arriba. En Copiloto, estilo atajos: Preguntar ⌃⌥↩ · Ocultar ⌃⌥P · reloj · micrófono.
    private var header: some View {
        HStack(spacing: 10) {
            ModeSwitch(selection: $model.panelMode)
            if isCopilot {
                Spacer(minLength: 6)
                ViewThatFits(in: .horizontal) {
                    copilotTools(.full)
                    copilotTools(.askOnly)
                    copilotTools(.compact)
                }
            } else {
                ScriptPicker(model: model, store: model.store)
                Spacer(minLength: 8)
                DetectionBadge(monitor: monitor, settings: settings)
                ElapsedLabel(engine: engine)
            }
            PanelMenu(model: model, copilot: copilot)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 44)
        .background { if !docked { WindowDragArea() } }
    }

    private enum ToolsWidth { case full, askOnly, compact }

    /// Herramientas del Copiloto, de más a menos completas según el ancho del panel.
    private func copilotTools(_ width: ToolsWidth) -> some View {
        HStack(spacing: 6) {
            if width == .compact {
                CircleButton(icon: .aiMagic, size: 28) { copilot.suggest() }
                    .help("Ask the AI what to say now (⌃⌥↩)")
            } else {
                ToolbarAction(title: "Ask", keys: [.control, .option, .returnKey]) { copilot.suggest() }
                    .help("Ask the AI what to say now (⌃⌥↩)")
            }
            if width == .full {
                ToolbarAction(title: "Hide", keys: [.control, .option, .letter("P")]) { model.collapsePrompter() }
                    .help("Show / hide the panel (⌃⌥P)")
            }
            ListeningClock(since: copilot.listeningSince)
                .padding(.leading, 6)
                .padding(.trailing, 4)
            MicButton(copilot: copilot)
        }
    }

    @ViewBuilder private var content: some View {
        if isCopilot {
            CopilotPanelContent(copilot: copilot, fontSize: CGFloat(min(max(settings.fontSize * 0.6, 17), 28)))
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 18)
        } else if engine.text.isEmpty {
            VStack(spacing: 6) {
                Text("No script")
                    .font(.display(15, .semibold))
                    .foregroundStyle(.white)
                Text("Choose or write one in the Cue window.")
                    .font(.text(13))
                    .foregroundStyle(Theme.secondaryText)
            }
        } else {
            PrompterView(engine: engine, settings: settings, guideRatio: 0.3, horizontalPadding: 40)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                             .init(color: .black, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            CircleButton(icon: .previous, size: 32) { engine.stop() }
                .help("Back to start (R)")
            Button { engine.togglePlay() } label: {
                HugeIcon(engine.isActive ? .pause : .play, size: 16, filled: true)
                    .foregroundStyle(engine.isActive ? Color.white : .black)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(engine.isActive ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.pearl)))
            }
            .buttonStyle(PressableStyle())
            .help("Play / pause (space)")
            QuickAdjustBar(settings: settings)
            Spacer(minLength: 0)
            CircleButton(icon: .mirror, size: 32, active: settings.mirror) { settings.mirror.toggle() }
                .help("Mirror mode (M)")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 14)
        .background(LinearGradient(stops: [
            .init(color: PanelStyle.fill.opacity(0), location: 0),
            .init(color: PanelStyle.fill.opacity(0.55), location: 0.4),
            .init(color: PanelStyle.fill.opacity(0.7), location: 1),
        ], startPoint: .top, endPoint: .bottom))
    }
}

/// Bordes invisibles para cambiar el tamaño (la ventana no tiene marco del sistema): lados, base y
/// esquinas de abajo. No se dibuja nada; solo cambia el cursor al pasar por encima.
private struct ResizeEdges: View {
    let model: MacAppModel
    /// Distancia del borde de la vista al lado visible del panel (los hombros del notch).
    let inset: CGFloat
    /// Los lados empiezan aquí (debajo del notch).
    let top: CGFloat
    private let thickness: CGFloat = 8
    private let corner: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let half = thickness / 2
            let left = max(inset, half), right = min(w - inset, w - half)
            let sideHeight = max(0, h - top - corner)
            handle(.left)
                .frame(width: thickness, height: sideHeight)
                .position(x: left, y: top + sideHeight / 2)
            handle(.right)
                .frame(width: thickness, height: sideHeight)
                .position(x: right, y: top + sideHeight / 2)
            handle(.bottom)
                .frame(width: max(0, right - left - corner * 2), height: thickness)
                .position(x: w / 2, y: h - half)
            handle(.bottomLeft)
                .frame(width: corner, height: corner)
                .position(x: left - half + corner / 2, y: h - corner / 2)
            handle(.bottomRight)
                .frame(width: corner, height: corner)
                .position(x: right + half - corner / 2, y: h - corner / 2)
        }
    }

    private func handle(_ edge: PrompterPanelController.ResizeEdge) -> some View {
        ResizeHandle(controller: model.panel, edge: edge)
    }
}

private struct ResizeHandle: NSViewRepresentable {
    let controller: PrompterPanelController
    let edge: PrompterPanelController.ResizeEdge

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.controller = controller
        view.edge = edge
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.edge = edge
    }

    final class HandleView: NSView {
        weak var controller: PrompterPanelController?
        var edge: PrompterPanelController.ResizeEdge = .bottom
        private var start: NSPoint?

        override var mouseDownCanMoveWindow: Bool { false }
        /// El panel no se activa al hacer clic: sin esto el primer clic no empezaría el arrastre.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            // activeAlways: el panel casi nunca es la ventana principal, y el cursor debe cambiar igual.
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func cursorUpdate(with event: NSEvent) { edge.cursor.set() }
        override func mouseEntered(with event: NSEvent) { edge.cursor.set() }
        override func mouseExited(with event: NSEvent) {
            if start == nil { NSCursor.arrow.set() }
        }

        override func mouseDown(with event: NSEvent) {
            start = NSEvent.mouseLocation
            controller?.beginResize()
            edge.cursor.set()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let now = NSEvent.mouseLocation
            controller?.resize(translation: CGSize(width: now.x - start.x, height: start.y - now.y), edge: edge)
            edge.cursor.set()
        }

        override func mouseUp(with event: NSEvent) {
            start = nil
            controller?.endResize()
            if !bounds.contains(convert(event.locationInWindow, from: nil)) { NSCursor.arrow.set() }
        }
    }
}

/// Selector Guion / Copiloto.
struct ModeSwitch: View {
    @Binding var selection: MacAppModel.PanelMode
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MacAppModel.PanelMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.label)
                        .font(.display(12, .semibold))
                        .foregroundStyle(selection == mode ? .black : .white.opacity(0.62))
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background {
                            if selection == mode {
                                Pill().fill(Theme.pearl)
                                    .matchedGeometryEffect(id: "mode", in: namespace)
                            }
                        }
                        .contentShape(Pill())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Pill().fill(.white.opacity(0.06)))
        .overlay(Pill().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .fixedSize()
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selection)
    }
}

/// Punto que indica si se detecta grabación.
struct DetectionBadge: View {
    @ObservedObject var monitor: RecordingMonitor
    @ObservedObject var settings: PrompterSettings

    var body: some View {
        if settings.autoStart != .off {
            let active = monitor.cameraInUse || (settings.autoStart == .cameraOrMicrophone && monitor.microphoneInUse)
            HStack(spacing: 5) {
                Circle()
                    .fill(active ? Theme.record : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)
                Text(active ? "Recording" : "Waiting for camera")
                    .font(.display(12, .medium))
                    .foregroundStyle(.white.opacity(active ? 0.9 : 0.45))
            }
            .lineLimit(1)
            .help("Cue starts on its own when another app turns on the camera")
        }
    }
}

/// Zona para arrastrar la ventana.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
