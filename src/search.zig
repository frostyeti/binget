const std = @import("std");
const platform = @import("platform.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const search_help =
    \\Search the remote registry for a package.
    \\
    \\Usage:
    \\  binget search <query> [-e]
    \\  binget search -h | --help
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
            std.debug.print("{s}", .{search_help});
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return;
        } else {
            query = arg;
        }
        i += 1;
    }

    const q = query orelse {
        std.debug.print("Error: search query required.\n\n{s}", .{search_help});
        return error.InvalidArgument;
    };

    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);

    const manifest_path = try std.fs.path.join(allocator, &.{ share_dir, "manifest.db" });
    defer allocator.free(manifest_path);

    if (std.fs.cwd().access(manifest_path, .{}) == error.FileNotFound) {
        std.debug.print("Sources not found. Run `binget sources update` first.\n", .{});
        return error.FileNotFound;
    }

    const manifest_path_z = try allocator.dupeZ(u8, manifest_path);
    defer allocator.free(manifest_path_z);

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(manifest_path_z.ptr, &db, c.SQLITE_OPEN_READONLY, null) != c.SQLITE_OK) {
        std.debug.print("Failed to open manifest.db\n", .{});
        return error.DatabaseError;
    }
    defer _ = c.sqlite3_close(db);

    const query_str = if (exact) "SELECT id, description FROM packages WHERE id = ?" else "SELECT id, description FROM packages WHERE id LIKE ?";
    var stmt: ?*c.sqlite3_stmt = null;

    if (c.sqlite3_prepare_v2(db, query_str.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        // Just print raw error
        std.debug.print("Error preparing query. Maybe manifest.db is empty or invalid.\n", .{});
        return;
    }
    defer _ = c.sqlite3_finalize(stmt);

    var bind_str: []const u8 = undefined;
    if (exact) {
        bind_str = try allocator.dupeZ(u8, q);
    } else {
        bind_str = try std.fmt.allocPrint(allocator, "%{s}%\x00", .{q});
    }
    defer allocator.free(bind_str);

    _ = c.sqlite3_bind_text(stmt, 1, bind_str.ptr, -1, null);

    var found = false;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        found = true;
        const id_ptr = c.sqlite3_column_text(stmt, 0);
        const desc_ptr = c.sqlite3_column_text(stmt, 1);

        const id_str = if (id_ptr != null) std.mem.span(id_ptr) else "";
        const desc_str = if (desc_ptr != null) std.mem.span(desc_ptr) else "";

        std.debug.print("{s} - {s}\n", .{ id_str, desc_str });
    }

    if (!found) {
        std.debug.print("No packages found matching '{s}'\n", .{q});
    }
}
