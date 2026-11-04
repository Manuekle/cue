import Foundation

struct Script: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var body: String
    var updatedAt = Date()
    /// Sesión a la que pertenece. `nil` = sin sesión (solo aparece en "Todos").
    var sessionID: Session.ID?

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.isEmpty ? String(localized: "Untitled") : String(firstLine.prefix(40))
    }

    var preview: String {
        body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    var wordCount: Int { Script.countWords(body) }

    static func countWords(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    static let sample = Script(
        title: String(localized: "Welcome to Cue"),
        body: String(localized: """
        Hi. This is your first practice script.

        Write or paste what you want to say here. Cue shows it big, clear and at the speed you choose.

        Before you start, a countdown gives you time to get settled in front of the camera.

        See the arrow on the left: that's your reading line. Always read at that height and your gaze will look natural.

        Tap the text to pause. Swipe to move forward or back.

        If you're going too fast or too slow, adjust the speed with the minus and plus buttons.

        Done! Now delete this text and write your own script.
        """)
    )
}
