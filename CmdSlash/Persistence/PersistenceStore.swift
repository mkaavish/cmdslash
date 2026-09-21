import Foundation
import SQLite3
import os

/// Local-only persistence for CmdSlash's action history (Docs/PLANNING.md §39) — a durable,
/// queryable record of what the agent actually did, independent of OverlayViewModel's in-memory
/// state, which resets on every dismiss. Uses the raw SQLite3 C API rather than a wrapper library
/// (GRDB was the plan's suggestion, §44): this Xcode project uses the newer file-system-
/// synchronized format, and hand-editing a Swift Package reference into project.pbxproj (several
/// interlocking sections, no Xcode validation) is real risk for what's otherwise a small,
/// self-contained surface — the C API is standard and sufficient here.
///
/// Scoped simpler than §39's full 4-table schema on purpose: one `sessions` row per `⌘/` command,
/// with the tool calls made during it stored as an embedded JSON array rather than a separate
/// normalized table. Nothing queries at the individual-tool-call level yet (no history UI exists)
/// — that's real work to add later if a feature actually needs it, not now.
final class PersistenceStore {
    static let shared = PersistenceStore()

    private let logger = Logger(subsystem: "com.cmdslash.CmdSlash", category: "PersistenceStore")
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.cmdslash.persistence.queue")

    struct SessionRecord {
        let id: String
        let startedAt: Date
        let endedAt: Date?
        let inputMode: String
        let rawText: String
        let outcome: String?
        let summary: String?
        let toolCallsJSON: String?
    }

    private init() {
        openDatabase()
        createSchemaIfNeeded()
    }

    private func openDatabase() {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            logger.error("Couldn't resolve Application Support directory")
            return
        }
        let directory = appSupport.appendingPathComponent("CmdSlash", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logger.error("Couldn't create data directory: \(error.localizedDescription, privacy: .public)")
            return
        }
        let dbURL = directory.appendingPathComponent("cmdslash.sqlite")

        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            logger.error("Couldn't open database at \(dbURL.path, privacy: .public)")
            db = nil
        }
    }

    private func createSchemaIfNeeded() {
        runStatement("""
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            started_at REAL NOT NULL,
            ended_at REAL,
            input_mode TEXT NOT NULL,
            raw_text TEXT NOT NULL,
            outcome TEXT,
            summary TEXT,
            tool_calls_json TEXT
        )
        """)
    }

    // MARK: - Writes

    func beginSession(id: String, inputMode: String, rawText: String) {
        runStatement("INSERT INTO sessions (id, started_at, input_mode, raw_text) VALUES (?, ?, ?, ?)") { statement in
            sqlite3_bind_text(statement, 1, id, -1, Self.transient)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(statement, 3, inputMode, -1, Self.transient)
            sqlite3_bind_text(statement, 4, rawText, -1, Self.transient)
        }
    }

    func endSession(id: String, outcome: String, summary: String?, toolCallsJSON: String?) {
        runStatement("UPDATE sessions SET ended_at = ?, outcome = ?, summary = ?, tool_calls_json = ? WHERE id = ?") { statement in
            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(statement, 2, outcome, -1, Self.transient)
            Self.bindOptionalText(statement, 3, summary)
            Self.bindOptionalText(statement, 4, toolCallsJSON)
            sqlite3_bind_text(statement, 5, id, -1, Self.transient)
        }
    }

    // MARK: - Reads

    func recentSessions(limit: Int = 50) -> [SessionRecord] {
        queue.sync {
            guard let db else { return [] }
            let sql = "SELECT id, started_at, ended_at, input_mode, raw_text, outcome, summary, tool_calls_json FROM sessions ORDER BY started_at DESC LIMIT ?"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                logPrepareError()
                return []
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))

            var results: [SessionRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(SessionRecord(
                    id: Self.text(statement, 0) ?? "",
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    endedAt: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    inputMode: Self.text(statement, 3) ?? "",
                    rawText: Self.text(statement, 4) ?? "",
                    outcome: Self.text(statement, 5),
                    summary: Self.text(statement, 6),
                    toolCallsJSON: Self.text(statement, 7)
                ))
            }
            return results
        }
    }

    // MARK: - Helpers

    private func runStatement(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                self.logPrepareError()
                return
            }
            defer { sqlite3_finalize(statement) }
            if let statement, let bind {
                bind(statement)
            }
            if sqlite3_step(statement) != SQLITE_DONE {
                self.logStepError()
            }
        }
    }

    private static func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL, let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cString)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func logPrepareError() {
        guard let db else { return }
        logger.error("sqlite3_prepare_v2 failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
    }

    private func logStepError() {
        guard let db else { return }
        logger.error("sqlite3_step failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
    }
}
