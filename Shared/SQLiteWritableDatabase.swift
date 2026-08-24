import Foundation
import SQLite3

enum SQLiteWritableDatabaseError: LocalizedError {
    case invalidFileURL(URL)
    case openFailed(path: String, code: Int32, message: String)
    case operationFailed(operation: String, code: Int32, message: String)
    case unexpectedColumnType(index: Int32, expected: String, actual: Int32)
    case invalidUTF8(index: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidFileURL(let url):
            return "The writable database URL is not a local file: \(url.absoluteString)"
        case .openFailed(let path, let code, let message):
            return "Could not open the writable database at \(path) (SQLite \(code)): \(message)"
        case .operationFailed(let operation, let code, let message):
            return "The writable database failed while \(operation) (SQLite \(code)): \(message)"
        case .unexpectedColumnType(let index, let expected, let actual):
            return "Column \(index) should contain \(expected), but SQLite reported type \(actual)."
        case .invalidUTF8(let index):
            return "Column \(index) contains text that is not valid UTF-8."
        }
    }
}

enum SQLiteWritableBinding {
    case text(String)
    case integer(Int64)
    case null
}

/// A small serialized SQLite connection for application-owned state.
///
/// The immutable content pack deliberately uses a different, read-only
/// connection type. Keeping the connections separate makes it impossible for
/// an overlay write or migration to modify the bundled database by accident.
final class SQLiteWritableDatabase: @unchecked Sendable {
    private let connection: OpaquePointer
    private let lock = NSRecursiveLock()

    init(url: URL, fileManager: FileManager = .default) throws {
        guard url.isFileURL else {
            throw SQLiteWritableDatabaseError.invalidFileURL(url)
        }

        let parentURL = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )

        var openedConnection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openResult = url.withUnsafeFileSystemRepresentation { path in
            sqlite3_open_v2(path, &openedConnection, flags, nil)
        }

        guard openResult == SQLITE_OK, let openedConnection else {
            let message = openedConnection.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite did not return an error message."
            if let openedConnection {
                sqlite3_close_v2(openedConnection)
            }
            throw SQLiteWritableDatabaseError.openFailed(
                path: url.path,
                code: openResult,
                message: message
            )
        }

        sqlite3_extended_result_codes(openedConnection, 1)
        sqlite3_busy_timeout(openedConnection, 5_000)

        do {
            try Self.executePragma(
                "PRAGMA foreign_keys = ON",
                operation: "enabling foreign keys",
                connection: openedConnection
            )
            try Self.executePragma(
                "PRAGMA journal_mode = WAL",
                operation: "enabling write-ahead logging",
                connection: openedConnection
            )
            try Self.executePragma(
                "PRAGMA synchronous = NORMAL",
                operation: "configuring durable writes",
                connection: openedConnection
            )
        } catch {
            sqlite3_close_v2(openedConnection)
            throw error
        }

        connection = openedConnection
    }

    deinit {
        sqlite3_close_v2(connection)
    }

    @discardableResult
    func execute(
        _ sql: String,
        bindings: [SQLiteWritableBinding] = []
    ) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        let statement = try prepare(sql, operation: "preparing a write")
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_DONE else {
            throw operationError("executing a write", code: stepResult)
        }
        return Int(sqlite3_changes(connection))
    }

    func executeScript(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(connection))
            sqlite3_free(errorMessage)
            throw SQLiteWritableDatabaseError.operationFailed(
                operation: "executing a SQL script",
                code: result,
                message: message
            )
        }
    }

    func queryOne<Result>(
        _ sql: String,
        bindings: [SQLiteWritableBinding] = [],
        transform: (SQLiteWritableRow) throws -> Result
    ) throws -> Result? {
        try query(sql, bindings: bindings, maximumRowCount: 1, transform: transform).first
    }

    func query<Result>(
        _ sql: String,
        bindings: [SQLiteWritableBinding] = [],
        transform: (SQLiteWritableRow) throws -> Result
    ) throws -> [Result] {
        try query(sql, bindings: bindings, maximumRowCount: nil, transform: transform)
    }

    func withTransaction<Result>(_ body: () throws -> Result) throws -> Result {
        lock.lock()
        defer { lock.unlock() }

        try executeScript("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try executeScript("COMMIT")
            return result
        } catch {
            try? executeScript("ROLLBACK")
            throw error
        }
    }

    private func query<Result>(
        _ sql: String,
        bindings: [SQLiteWritableBinding],
        maximumRowCount: Int?,
        transform: (SQLiteWritableRow) throws -> Result
    ) throws -> [Result] {
        lock.lock()
        defer { lock.unlock() }

        let statement = try prepare(sql, operation: "preparing a query")
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var results: [Result] = []
        while true {
            let stepResult = sqlite3_step(statement)
            switch stepResult {
            case SQLITE_ROW:
                results.append(try transform(SQLiteWritableRow(statement: statement)))
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

    private func prepare(_ sql: String, operation: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw operationError(operation, code: result)
        }
        return statement
    }

    private func bind(_ bindings: [SQLiteWritableBinding], to statement: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .text(let value):
                result = value.withCString { pointer in
                    sqlite3_bind_text(statement, index, pointer, -1, writableSQLiteTransient)
                }
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw operationError("binding parameter \(index)", code: result)
            }
        }
    }

    private func operationError(_ operation: String, code: Int32) -> SQLiteWritableDatabaseError {
        SQLiteWritableDatabaseError.operationFailed(
            operation: operation,
            code: code,
            message: String(cString: sqlite3_errmsg(connection))
        )
    }

    private static func executePragma(
        _ sql: String,
        operation: String,
        connection: OpaquePointer
    ) throws {
        let result = sqlite3_exec(connection, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteWritableDatabaseError.operationFailed(
                operation: operation,
                code: result,
                message: String(cString: sqlite3_errmsg(connection))
            )
        }
    }
}

struct SQLiteWritableRow {
    fileprivate let statement: OpaquePointer

    func text(at index: Int32) throws -> String {
        let type = sqlite3_column_type(statement, index)
        guard type == SQLITE_TEXT else {
            throw SQLiteWritableDatabaseError.unexpectedColumnType(
                index: index,
                expected: "text",
                actual: type
            )
        }
        guard let bytes = sqlite3_column_text(statement, index) else {
            throw SQLiteWritableDatabaseError.invalidUTF8(index: index)
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        let data = Data(bytes: bytes, count: count)
        guard let value = String(data: data, encoding: .utf8) else {
            throw SQLiteWritableDatabaseError.invalidUTF8(index: index)
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
            throw SQLiteWritableDatabaseError.unexpectedColumnType(
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
}

private let writableSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
