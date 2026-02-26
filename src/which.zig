const std = @import("std");
const platform = @import("platform.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const which_help =
    \\Locate the physical installation of a package.
    \\
    \\Usage:
    \\  binget which <name>
    \\  binget which -h | --help
    \\
    \\Options:
    \\  -h, --help       Show this help message and exit
    \\
;

pub fn parseAndRun(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 3 or std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help")) {
        std.debug.print("{s}", .{which_help});
        return;
    }

    const target = args[2];

    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);

    const db_path = try std.fs.path.join(allocator, &.{ share_dir, "binget.db" });
    defer allocator.free(db_path);

    if (std.fs.cwd().access(db_path, .{}) == error.FileNotFound) {
        std.debug.print("No packages installed yet.\n", .{});
        return;
    }

    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(db_path_z.ptr, &db, c.SQLITE_OPEN_READONLY, null) != c.SQLITE_OK) {
        std.debug.print("Failed to open binget.db\n", .{});
        return error.DatabaseError;
    }
    defer _ = c.sqlite3_close(db);

    const query_str = "SELECT install_path FROM installed_packages WHERE name = ? LIMIT 1";
    var stmt: ?*c.sqlite3_stmt = null;

    if (c.sqlite3_prepare_v2(db, query_str.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        std.debug.print("Error preparing query.\n", .{});
        return;
    }
    defer _ = c.sqlite3_finalize(stmt);

    const bind_str = try allocator.dupeZ(u8, target);
    defer allocator.free(bind_str);

    _ = c.sqlite3_bind_text(stmt, 1, bind_str.ptr, -1, null);

    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const path_ptr = c.sqlite3_column_text(stmt, 0);
        if (path_ptr != null) {
            std.debug.print("{s}\n", .{std.mem.span(path_ptr)});
        }
    } else {
        std.debug.print("Package '{s}' not found in installed packages.\n", .{target});
    }
}
