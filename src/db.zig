const std = @import("std");
const c = @import("main.zig").c;

pub const Database = struct {
    db: *c.sqlite3,

    pub fn open(path: [:0]const u8) !Database {
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path.ptr, &db) != c.SQLITE_OK) {
            std.debug.print("Cannot open database: {s}\n", .{c.sqlite3_errmsg(db)});
            return error.SqliteOpenFailed;
        }

        const self = Database{ .db = db.? };
        try self.runMigrations();
        return self;
    }

    pub fn close(self: Database) void {
        _ = c.sqlite3_close(self.db);
    }

    const Migration = struct {
        id: i32,
        name: [:0]const u8,
        up: [:0]const u8,
    };

    const migrations = [_]Migration{
        .{
            .id = 1,
            .name = "001_initial_schema",
            .up =
                \\CREATE TABLE installed_packages (
                \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
                \\  name TEXT NOT NULL,
                \\  version TEXT NOT NULL,
                \\  install_path TEXT NOT NULL,
                \\  is_global BOOLEAN NOT NULL DEFAULT 0,
                \\  UNIQUE(name, version)
                \\);
            ,
        },
        // Future migrations can be added here
    };

    fn runMigrations(self: Database) !void {
        // Ensure migrations table exists
        const init_mig_table =
            \\CREATE TABLE IF NOT EXISTS migrations (
            \\  id INTEGER PRIMARY KEY,
            \\  name TEXT NOT NULL,
            \\  applied_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\);
        ;
        try self.exec(init_mig_table);

        for (migrations) |mig| {
            var applied = false;
            
            var stmt: ?*c.sqlite3_stmt = null;
            const check_query = "SELECT 1 FROM migrations WHERE id = ?";
            if (c.sqlite3_prepare_v2(self.db, check_query, -1, &stmt, null) == c.SQLITE_OK) {
                _ = c.sqlite3_bind_int(stmt, 1, mig.id);
                if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                    applied = true;
                }
                _ = c.sqlite3_finalize(stmt);
            }

            if (!applied) {
                std.debug.print("Running migration: {s}...\n", .{mig.name});
                // Use a transaction for the migration
                try self.exec("BEGIN TRANSACTION;");
                
                // We use c.sqlite3_exec directly for multiple statements in migration.up
                var err_msg: [*c]u8 = null;
                if (c.sqlite3_exec(self.db, mig.up.ptr, null, null, &err_msg) != c.SQLITE_OK) {
                    std.debug.print("Migration {s} failed: {s}\n", .{mig.name, err_msg});
                    c.sqlite3_free(err_msg);
                    _ = self.exec("ROLLBACK;") catch {};
                    return error.MigrationFailed;
                }

                var record_stmt: ?*c.sqlite3_stmt = null;
                const record_query = "INSERT INTO migrations (id, name) VALUES (?, ?)";
                if (c.sqlite3_prepare_v2(self.db, record_query, -1, &record_stmt, null) == c.SQLITE_OK) {
                    _ = c.sqlite3_bind_int(record_stmt, 1, mig.id);
                    _ = c.sqlite3_bind_text(record_stmt, 2, mig.name.ptr, -1, c.SQLITE_STATIC);
                    if (c.sqlite3_step(record_stmt) != c.SQLITE_DONE) {
                         _ = self.exec("ROLLBACK;") catch {};
                         _ = c.sqlite3_finalize(record_stmt);
                         return error.MigrationRecordFailed;
                    }
                    _ = c.sqlite3_finalize(record_stmt);
                }
                
                try self.exec("COMMIT;");
            }
        }
    }

    pub fn exec(self: Database, query: [:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        if (c.sqlite3_exec(self.db, query.ptr, null, null, &err_msg) != c.SQLITE_OK) {
            std.debug.print("SQL error: {s}\n", .{err_msg});
            c.sqlite3_free(err_msg);
            return error.SqliteExecFailed;
        }
    }

    pub fn recordInstall(self: Database, name: [:0]const u8, version: [:0]const u8, install_path: [:0]const u8, is_global: bool) !void {
        var stmt: ?*c.sqlite3_stmt = null;
        const query = "INSERT OR REPLACE INTO installed_packages (name, version, install_path, is_global) VALUES (?, ?, ?, ?)";
        
        if (c.sqlite3_prepare_v2(self.db, query, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, name.ptr, -1, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, version.ptr, -1, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, install_path.ptr, -1, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_int(stmt, 4, if (is_global) 1 else 0);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn getInstalledVersion(self: Database, allocator: std.mem.Allocator, name: [:0]const u8) !?[]u8 {
        var stmt: ?*c.sqlite3_stmt = null;
        const query = "SELECT version FROM installed_packages WHERE name = ? ORDER BY id DESC LIMIT 1";
        
        if (c.sqlite3_prepare_v2(self.db, query, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, name.ptr, -1, c.SQLITE_STATIC);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const version_c = c.sqlite3_column_text(stmt, 0);
            if (version_c != null) {
                return try allocator.dupe(u8, std.mem.span(version_c));
            }
        }
        return null;
    }
};
