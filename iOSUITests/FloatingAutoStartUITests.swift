import XCTest

/// Prueba de punta a punta en un iPhone real (el simulador no tiene ventana flotante ni Cámara):
/// abre la ventana flotante, graba unos segundos con la app Cámara y comprueba que el texto
/// arrancó solo. Deja un video corto de prueba en Fotos.
final class FloatingAutoStartUITests: XCTestCase {
    private let app = XCUIApplication()
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let camera = XCUIApplication(bundleIdentifier: "com.apple.camera")

    override func setUp() {
        continueAfterFailure = false
    }

    func testFloatingWindowStartsWhenCameraRecords() throws {
        app.launch()
        let firstScript = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'palabras'")).firstMatch
        XCTAssertTrue(firstScript.waitForExistence(timeout: 10))
        firstScript.tap()

        let floatingTile = app.buttons["launch-floating"]
        XCTAssertTrue(floatingTile.waitForExistence(timeout: 5))
        floatingTile.tap()
        answerSystemAlerts(for: 4)

        let openWindow = app.buttons["toggle-pip"]
        XCTAssertTrue(openWindow.waitForExistence(timeout: 5))
        waitUntil(timeout: 10) { openWindow.isEnabled }
        sleep(2)
        openWindow.tap()
        sleep(2)

        camera.activate()
        XCTAssertTrue(camera.wait(for: .runningForeground, timeout: 10))
        answerSystemAlerts(for: 3)
        switchCameraToVideo()

        let shutter = try XCTUnwrap(findShutter(), "No encontré el botón de grabar.\n\(camera.debugDescription)")
        shutter.tap()       // empieza a grabar
        sleep(8)            // cuenta regresiva + unos segundos de texto
        shutter.tap()       // deja de grabar
        sleep(3)

        app.activate()
        let elapsed = app.descendants(matching: .any)["elapsed"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        let first = elapsed.label
        sleep(2)
        let second = elapsed.label
        print("PRONTER-ELAPSED: \(first) -> \(second)")
        print("PRONTER-PAUSED-AFTER-STOP: \(first == second ? "sí" : "no")")
        XCTAssertFalse(first.hasPrefix("0:00"), "El texto no arrancó solo (tiempo \(first))")
    }

    // MARK: Ayudantes

    /// Permite el micrófono a Pronter; cualquier otro permiso (ubicación de Cámara, etc.) se rechaza.
    private func answerSystemAlerts(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let alert = springboard.alerts.firstMatch
            if alert.exists {
                let isPronter = alert.label.localizedCaseInsensitiveContains("Cue")
                let choices = isPronter ? ["Permitir", "Allow", "OK"] : ["No permitir", "Don’t Allow", "Don't Allow", "Ahora no", "OK"]
                if let button = choices.lazy.map({ alert.buttons[$0] }).first(where: { $0.exists }) {
                    button.tap()
                } else {
                    alert.buttons.element(boundBy: 0).tap()
                }
            }
            usleep(300_000)
        }
    }

    private func switchCameraToVideo() {
        for label in ["VIDEO", "Video", "VÍDEO", "Vídeo"] {
            for element in [camera.buttons[label], camera.staticTexts[label], camera.otherElements[label]] where element.exists {
                element.tap()
                sleep(2)
                return
            }
        }
        // En la Cámara, el modo Video está a la izquierda de Foto.
        camera.swipeRight()
        sleep(2)
    }

    private func findShutter() -> XCUIElement? {
        let predicate = NSPredicate(format: """
            identifier CONTAINS[c] 'capture' OR identifier CONTAINS[c] 'shutter' \
            OR label CONTAINS[c] 'grabar' OR label CONTAINS[c] 'grabación' OR label CONTAINS[c] 'record'
            """)
        let match = camera.buttons.matching(predicate).firstMatch
        return match.waitForExistence(timeout: 5) ? match : nil
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { usleep(200_000) }
    }
}
