import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum ClipboardRepresentationStore {
    nonisolated static func read(
        for id: UUID, inDatabaseAt url: URL
    ) -> [ClipboardRepresentation] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return []
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_exec(db, "PRAGMA cache_size=-1024", nil, nil, nil)
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db,
                "SELECT uti, data FROM item_representations WHERE item_id = ? ORDER BY rowid",
                -1, &stmt, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        var result: [ClipboardRepresentation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let type = columnString(stmt, 0), ClipboardRepresentation.allowedTypes.contains(type) else {
                continue
            }
            let count = Int(sqlite3_column_bytes(stmt, 1))
            guard count <= ClipboardRepresentation.maximumBytes,
                result.reduce(0, { $0 + $1.data.count }) + count <= ClipboardRepresentation.maximumEntryBytes,
                let bytes = sqlite3_column_blob(stmt, 1)
            else { continue }
            result.append(ClipboardRepresentation(type: type, data: Data(bytes: bytes, count: count)))
        }
        return ClipboardRepresentation.bounded(result)
    }

    @discardableResult
    nonisolated static func write(
        _ representations: [ClipboardRepresentation], for id: UUID, inDatabaseAt url: URL,
        matchingText: String? = nil
    ) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return []
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 5_000)
        sqlite3_exec(db, "PRAGMA cache_size=-1024", nil, nil, nil)
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_exec(db, "COMMIT", nil, nil, nil) }
        if let matchingText {
            var check: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT text FROM items WHERE id = ?", -1, &check, nil) == SQLITE_OK
            else {
                return []
            }
            sqlite3_bind_text(check, 1, id.uuidString, -1, SQLITE_TRANSIENT)
            let matches = sqlite3_step(check) == SQLITE_ROW && columnString(check, 0) == matchingText
            sqlite3_finalize(check)
            guard matches else { return [] }
        }
        return write(representations, for: id, in: db)
    }

    nonisolated static func write(
        _ representations: [ClipboardRepresentation], for id: UUID, in db: OpaquePointer?
    ) -> [String] {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM item_representations WHERE item_id = ?", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        stmt = nil
        sqlite3_prepare_v2(
            db, "SELECT COALESCE(SUM(byte_count), 0) FROM item_representations", -1, &stmt, nil)
        var bytes = sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        sqlite3_finalize(stmt)
        stmt = nil
        guard
            sqlite3_prepare_v2(
                db,
                """
                INSERT INTO item_representations(item_id, uti, data, byte_count)
                SELECT id, ?2, ?3, length(?3) FROM items WHERE id = ?1
                """, -1, &stmt, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(stmt) }
        var types: [String] = []
        for representation in ClipboardRepresentation.bounded(representations) {
            guard bytes + representation.data.count <= ClipboardRepresentation.maximumStoredBytes else {
                continue
            }
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, representation.type, -1, SQLITE_TRANSIENT)
            _ = representation.data.withUnsafeBytes {
                sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
            }
            if sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) > 0 {
                types.append(representation.type)
                bytes += representation.data.count
            }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        let json = (try? JSONEncoder().encode(types)) ?? Data("[]".utf8)
        var update: OpaquePointer?
        if sqlite3_prepare_v2(
            db, "UPDATE items SET representation_types = ?1 WHERE id = ?2",
            -1, &update, nil) == SQLITE_OK
        {
            let value = String(data: json, encoding: .utf8) ?? "[]"
            sqlite3_bind_text(update, 1, value, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(update, 2, id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_step(update)
        }
        sqlite3_finalize(update)
        return types
    }

    nonisolated private static func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return String(bytes: UnsafeBufferPointer(start: ptr, count: count), encoding: .utf8)
    }
}
