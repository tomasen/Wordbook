import Foundation
import SQLite3

enum SQLiteReadOnlyDatabaseError: LocalizedError {
    case invalidFileURL(URL)
    case openFailed(path: String, code: Int32, message: String)
    case operationFailed(operation: String, code: Int32, message: String)
    case unexpectedColumnType(index: Int32, expected: String, actual: Int32)
    case invalidUTF8(index: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidFileURL(let url):
            return "The content database URL is not a local file: \(url.absoluteString)"
        case .openFailed(let path, let code, let message):
            return "Could not open the content database at \(path) (SQLite \(code)): \(message)"
        case .operationFailed(let operation, let code, let message):
            return "The content database failed while \(operation) (SQLite \(code)): \(message)"
        case .unexpectedColumnType(let index, let expected, let actual):
            return "Column \(index) should contain \(expected), but SQLite reported type \(actual)."
        case .invalidUTF8(let index):
            return "Column \(index) contains text that is not valid UTF-8."
        }
    }
}

enum SQLiteBinding {
    case text(String)
    case integer(Int64)
    case null
}

/// A small, serialized SQLite reader for immutable application content.
///
/// This type deliberately exposes no mutation API. Statements are scoped to a
/// query callback, and the database is opened with both SQLite's read-only flag
/// and `PRAGMA query_only` so a future caller cannot accidentally modify a pack.
final class SQLiteReadOnlyDatabase: @unchecked Sendable {
    private let connection: OpaquePointer
    private let lock = NSLock()

    init(url: URL) throws {
        guard url.isFileURL else {
            throw SQLiteReadOnlyDatabaseError.invalidFileURL(url)
        }

        var openedConnection: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let openResult = url.withUnsafeFileSystemRepresentation { path in
            sqlite3_open_v2(path, &openedConnection, flags, nil)
        }

        guard openResult == SQLITE_OK, let openedConnection else {
            let message = openedConnection.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite did not return an error message."
            if let openedConnection {
                sqlite3_close_v2(openedConnection)
            }
            throw SQLiteReadOnlyDatabaseError.openFailed(
                path: url.path,
                code: openResult,
                message: message
            )
        }

        sqlite3_extended_result_codes(openedConnection, 1)

        let foreignKeyResult = sqlite3_exec(
            openedConnection,
            "PRAGMA foreign_keys = ON",
            nil,
            nil,
            nil
        )
        guard foreignKeyResult == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(openedConnection))
            sqlite3_close_v2(openedConnection)
            throw SQLiteReadOnlyDatabaseError.operationFailed(
                operation: "enabling foreign keys",
                code: foreignKeyResult,
                message: message
            )
        }

        let queryOnlyResult = sqlite3_exec(
            openedConnection,
            "PRAGMA query_only = ON",
            nil,
            nil,
            nil
        )
        guard queryOnlyResult == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(openedConnection))
            sqlite3_close_v2(openedConnection)
            throw SQLiteReadOnlyDatabaseError.operationFailed(
                operation: "enabling read-only query mode",
                code: queryOnlyResult,
                message: message
            )
        }

        connection = openedConnection
    }

    deinit {
        sqlite3_close_v2(connection)
    }

    func queryOne<Result>(
        _ sql: String,
        bindings: [SQLiteBinding] = [],
        transform: (SQLiteRow) throws -> Result
    ) throws -> Result? {
        try performQuery(
            sql,
            bindings: bindings,
            maximumRowCount: 1,
            transform: transform
        ).first
    }

    func query<Result>(
        _ sql: String,
        bindings: [SQLiteBinding] = [],
        transform: (SQLiteRow) throws -> Result
    ) throws -> [Result] {
        try performQuery(
            sql,
            bindings: bindings,
            maximumRowCount: nil,
            transform: transform
        )
    }

    private func performQuery<Result>(
        _ sql: String,
        bindings: [SQLiteBinding],
        maximumRowCount: Int?,
        transform: (SQLiteRow) throws -> Result
    ) throws -> [Result] {
        lock.lock()
        defer { lock.unlock() }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw operationError("preparing a query", code: prepareResult)
        }
        defer { sqlite3_finalize(statement) }

        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let bindResult: Int32
            switch binding {
            case .text(let value):
                bindResult = value.withCString { pointer in
                    sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
                }
            case .integer(let value):
                bindResult = sqlite3_bind_int64(statement, index, value)
            case .null:
                bindResult = sqlite3_bind_null(statement, index)
            }
            guard bindResult == SQLITE_OK else {
                throw operationError("binding query parameter \(index)", code: bindResult)
            }
        }

        var results: [Result] = []
        while true {
            let stepResult = sqlite3_step(statement)
            switch stepResult {
            case SQLITE_ROW:
                results.append(try transform(SQLiteRow(statement: statement)))
                if let maximumRowCount, results.count >= maximumRowCount {
                    return results
                }
            case SQLITE_DONE:
                return results
            default:
                throw operationError("reading query results", code: stepResult)
            }
        }
    }

    private func operationError(_ operation: String, code: Int32) -> SQLiteReadOnlyDatabaseError {
        SQLiteReadOnlyDatabaseError.operationFailed(
            operation: operation,
            code: code,
            message: String(cString: sqlite3_errmsg(connection))
        )
    }
}

struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func text(at index: Int32) throws -> String {
        let type = sqlite3_column_type(statement, index)
        guard type == SQLITE_TEXT else {
            throw SQLiteReadOnlyDatabaseError.unexpectedColumnType(
                index: index,
                expected: "text",
                actual: type
            )
        }
        guard let bytes = sqlite3_column_text(statement, index) else {
            throw SQLiteReadOnlyDatabaseError.invalidUTF8(index: index)
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        let data = Data(bytes: bytes, count: count)
        guard let value = String(data: data, encoding: .utf8) else {
            throw SQLiteReadOnlyDatabaseError.invalidUTF8(index: index)
        }
        return value
    }

    func optionalText(at index: Int32) throws -> String? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL {
            return nil
        }
        return try text(at: index)
    }

    func integer(at index: Int32) throws -> Int64 {
        let type = sqlite3_column_type(statement, index)
        guard type == SQLITE_INTEGER else {
            throw SQLiteReadOnlyDatabaseError.unexpectedColumnType(
                index: index,
                expected: "an integer",
                actual: type
            )
        }
        return sqlite3_column_int64(statement, index)
    }

    func optionalInteger(at index: Int32) throws -> Int64? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL {
            return nil
        }
        return try integer(at: index)
    }

    func data(at index: Int32) throws -> Data {
        let type = sqlite3_column_type(statement, index)
        guard type == SQLITE_BLOB else {
            throw SQLiteReadOnlyDatabaseError.unexpectedColumnType(
                index: index,
                expected: "binary data",
                actual: type
            )
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: count)
    }

    func optionalData(at index: Int32) throws -> Data? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL {
            return nil
        }
        return try data(at: index)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
