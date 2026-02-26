const std = @import("std");
const platform = @import("platform.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const list_help =
    \\List installed packages.
    \\
    \\Usage:
    \\  binget list [<query>] [-e]
    \\  binget list -h | --help
    \\
    \\Options:
    \\  -e, --exact      Exact match
    \\  -h, --help       Show this help message and exit
    \\
;

pub fn parseAndRun(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    var exact = false;
    var query: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--exact")) {
            exact = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{list_help});
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return;
        } else {
            query = arg;
        }
        i += 1;
    }

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

    const q = query;

    var query_str: []const u8 = "SELECT name, version, is_global FROM installed_packages ORDER BY name";
    if (q) |_| {
        query_str = if (exact) "SELECT name, version, is_global FROM installed_packages WHERE name = ? ORDER BY name" else "SELECT name, version, is_global FROM installed_packages WHERE name LIKE ? ORDER BY name";
    }

    var stmt: ?*c.sqlite3_stmt = null;

    if (c.sqlite3_prepare_v2(db, query_str.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        std.debug.print("Error preparing query.\n", .{});
        return;
    }
    defer _ = c.sqlite3_finalize(stmt);

    var bind_str: ?[]const u8 = null;
    defer if (bind_str) |b| allocator.free(b);

    if (q) |qv| {
        if (exact) {
            bind_str = try allocator.dupeZ(u8, qv);
        } else {
            bind_str = try std.fmt.allocPrint(allocator, "%{s}%\x00", .{qv});
        }
        _ = c.sqlite3_bind_text(stmt, 1, bind_str.?.ptr, -1, null);
    }

    var found = false;
    std.debug.print("{s:<30} | {s:<15} | {s}\n", .{ "NAME", "VERSION", "SCOPE" });
    std.debug.print("{s}\n", .{"-----------------------------------------------------------------"});

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        found = true;
        const name_ptr = c.sqlite3_column_text(stmt, 0);
        const version_ptr = c.sqlite3_column_text(stmt, 1);
        const is_global = c.sqlite3_column_int(stmt, 2) != 0;

        const name_str = if (name_ptr != null) std.mem.span(name_ptr) else "";
        const version_str = if (version_ptr != null) std.mem.span(version_ptr) else "";
        const scope_str = if (is_global) "global" else "user/shim";

        std.debug.print("{s:<30} | {s:<15} | {s}\n", .{ name_str, version_str, scope_str });
    }

    if (!found) {
        if (q) |qv| {
            std.debug.print("No installed packages found matching '{s}'\n", .{qv});
        } else {
            std.debug.print("No packages installed.\n", .{});
        }
    }
}
