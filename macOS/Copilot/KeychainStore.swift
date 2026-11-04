import Foundation
import Security

/// API keys de los proveedores de IA, guardadas en el llavero de macOS (nunca en UserDefaults).
enum KeychainStore {
    private static let service = "com.manudev.pronter.apikeys"
    /// Lo ya leído en esta sesión, para no tocar el llavero (ni pedir permiso) en cada sugerencia.
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    static func apiKey(for engine: LLMEngine) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[engine.rawValue] { return cached }
        var query = baseQuery(engine)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value = status == errSecSuccess ? (result as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "" : ""
        cache[engine.rawValue] = value
        return value
    }

    /// Guarda la clave (vacía = la borra).
    static func setAPIKey(_ key: String, for engine: LLMEngine) {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        cache[engine.rawValue] = value
        let query = baseQuery(engine)
        guard !value.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Cue · \(engine.label)"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func baseQuery(_ engine: LLMEngine) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: engine.rawValue]
    }
}
