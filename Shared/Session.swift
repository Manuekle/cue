import Foundation

/// Grupo de guiones. Cada guion pertenece a una sola sesión (o a ninguna).
struct Session: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()

    /// Nombre sin espacios sobrantes, o uno por defecto si quedó vacío.
    static func cleanName(_ raw: String, fallback: String = String(localized: "Session")) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(40))
    }
}
