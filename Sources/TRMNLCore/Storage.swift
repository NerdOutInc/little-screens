import Foundation
import CSQLite
import CryptoKit
import Security

struct Problem: Error, CustomStringConvertible {
    let status: Int
    let code: String
    let description: String
    init(_ status: Int, _ code: String, _ description: String) {
        self.status = status; self.code = code; self.description = description
    }
}

func jsonData(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func randomToken() -> String { UUID().uuidString.lowercased() + UUID().uuidString.lowercased() }

func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8), b = Array(rhs.utf8)
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for i in a.indices { difference |= a[i] ^ b[i] }
    return difference == 0
}

public enum SecretStore {
    public static func loadOrCreate(for directory: URL) throws -> Data {
        let account = digest(Data(directory.standardizedFileURL.path.utf8))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: "com.brianpattison.ai-trmnl",
                                  kSecAttrAccount as String: account]
        var result: CFTypeRef?
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return data }
        guard status == errSecItemNotFound else {
            throw Problem(500, "keychain_unavailable", "Keychain could not be read (\(status)).")
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Problem(500, "random_failed", "Could not create an installation secret.")
        }
        let data = Data(bytes)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw Problem(500, "keychain_unavailable", "Keychain could not save the installation secret (\(added)).")
        }
        return data
    }
}

struct Device: Codable {
    var id: String
    var mac: String
    var name: String
    var code: String
    var nonce: String
    var state: String
    var revision: Int
    var firmware: String
    var model: String
    var currentImage: String
    var lastSeen: Double?
    var lastImageServed: String?
    var lastImageServedAt: Double?
    var lastLog: String?
    var dashboard: SavedDashboard?
}

struct Publication: Codable {
    var id: String
    var deviceID: String
    var title: String
    var createdAt: Double
    var sha256: String
    var dashboardRevision: Int?
    var snapshot: DashboardSnapshot?
    var shownEvents: Int?
    var omittedEvents: Int?
    var truncatedTitles: Int?
}

struct Registry: Codable {
    var devices: [String: Device] = [:]
    var publications: [String: Publication] = [:]
    var pairingRevision = 0
    var pairingUntil: Double = 0
}

/// A single serial service owns this store. Registry snapshots and receipts commit together.
/// Keeping the small prototype registry in one versioned record avoids an ORM dependency.
final class Store {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("ai-trmnl.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw failure() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")
        let version = try rows("PRAGMA user_version").first?.first ?? "0"
        guard ["0", "1", "2"].contains(version) else {
            throw Problem(500, "newer_database", "This database needs a newer AI TRMNL version.")
        }
        try execute("CREATE TABLE IF NOT EXISTS registry (id INTEGER PRIMARY KEY CHECK(id=1), json TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS receipts (id TEXT PRIMARY KEY, digest TEXT NOT NULL, result TEXT NOT NULL)")
        try execute("PRAGMA user_version = 2")
    }

    deinit { sqlite3_close(db) }

    private func failure() -> Problem {
        Problem(500, "storage_error", db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite unavailable")
    }

    private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        for (i, value) in values.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(i + 1), value, -1, transient) == SQLITE_OK else {
                sqlite3_finalize(stmt); throw failure()
            }
        }
        return stmt
    }

    private func execute(_ sql: String, _ values: [String] = []) throws {
        let stmt = try statement(sql, values)
        defer { sqlite3_finalize(stmt) }
        let status = sqlite3_step(stmt)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw failure() }
    }

    private func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        let stmt = try statement(sql, values)
        defer { sqlite3_finalize(stmt) }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            result.append((0..<sqlite3_column_count(stmt)).map { index in
                sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
            })
        }
    }

    func load() throws -> Registry {
        guard let value = try rows("SELECT json FROM registry WHERE id=1").first?.first else { return Registry() }
        return try JSONDecoder().decode(Registry.self, from: Data(value.utf8))
    }

    func receipt(_ id: String, digest expected: String? = nil) throws -> [String: Any]? {
        guard let row = try rows("SELECT digest,result FROM receipts WHERE id=?", [id]).first else { return nil }
        if let expected, row[0] != expected {
            throw Problem(409, "request_id_conflict", "This request ID was already used for different input.")
        }
        return try JSONSerialization.jsonObject(with: Data(row[1].utf8)) as? [String: Any]
    }

    func save(_ registry: Registry, receipt: (String, String, [String: Any])? = nil) throws {
        let encoded = String(decoding: try JSONEncoder().encode(registry), as: UTF8.self)
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("INSERT INTO registry(id,json) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json", [encoded])
            if let (id, inputDigest, result) = receipt {
                // Fail rather than silently dropping retry history. A future migration can add archival.
                let count = Int(try rows("SELECT COUNT(*) FROM receipts")[0][0]) ?? 0
                guard count < 10000 else { throw Problem(507, "receipt_limit", "Prototype receipt limit reached; export/upgrade the store.") }
                try execute("INSERT INTO receipts(id,digest,result) VALUES(?,?,?)", [id, inputDigest, String(decoding: try jsonData(result), as: UTF8.self)])
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
