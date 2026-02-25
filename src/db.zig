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
        try self.initSchema();
        return self;
    }

    pub fn close(self: Database) void {
        _ = c.sqlite3_close(self.db);
    }

    fn initSchema(self: Database) !void {
        const query =
            \\CREATE TABLE IF NOT EXISTS installed_packages (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  name TEXT NOT NULL,
            \\  version TEXT NOT NULL,
            \\  install_path TEXT NOT NULL,
            \\  is_global BOOLEAN NOT NULL DEFAULT 0,
            \\  UNIQUE(name, version)
            \\);
        ;
        try self.exec(query);
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
                return allocator.dupe(u8, std.mem.span(version_c));
            }
        }
        return null;
    }
};
