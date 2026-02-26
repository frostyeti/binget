const std = @import("std");
const db = @import("db.zig");
const hooks = @import("hooks.zig");

pub fn uninstallPackage(allocator: std.mem.Allocator, db_conn: db.Database, target: []const u8, skip_prompts: bool) !void {
    var parts = std.mem.splitScalar(u8, target, '@');
    const id = parts.next().?;
    var version: ?[]const u8 = parts.next();
    var need_free_version = false;

    defer {
        if (need_free_version) {
            if (version) |v| allocator.free(v);
        }
    }

    if (version == null) {
        const id_z = try allocator.dupeZ(u8, id);
        defer allocator.free(id_z);
        if (try db_conn.getInstalledVersion(allocator, id_z)) |v| {
            version = v;
            need_free_version = true;
        }
    }

    std.debug.print("Uninstalling {s}...\n", .{target});

    try hooks.runHook(allocator, db_conn, .pre_uninstall, id, version, skip_prompts);

    // Core uninstall logic
    const share_dir = try @import("platform.zig").getBingetShareDir(allocator);
    defer allocator.free(share_dir);

    const pkg_dir = try std.fs.path.join(allocator, &.{ share_dir, "packages", id, version.? });
    defer allocator.free(pkg_dir);
    std.fs.cwd().deleteTree(pkg_dir) catch {};

    const env_dir = try std.fs.path.join(allocator, &.{ share_dir, "env", id, version.? });
    defer allocator.free(env_dir);
    std.fs.cwd().deleteTree(env_dir) catch {};

    // Remove from DB and delete the recorded install_path
    const id_z = try allocator.dupeZ(u8, id);
    defer allocator.free(id_z);
    const version_z = try allocator.dupeZ(u8, version.?);
    defer allocator.free(version_z);

    var stmt: ?*@import("main.zig").c.sqlite3_stmt = null;
    const query = "SELECT install_path FROM installed_packages WHERE name = ? AND version = ?";
    if (@import("main.zig").c.sqlite3_prepare_v2(db_conn.db, query, -1, &stmt, null) == @import("main.zig").c.SQLITE_OK) {
        _ = @import("main.zig").c.sqlite3_bind_text(stmt, 1, id_z.ptr, -1, @import("main.zig").c.SQLITE_STATIC);
        _ = @import("main.zig").c.sqlite3_bind_text(stmt, 2, version_z.ptr, -1, @import("main.zig").c.SQLITE_STATIC);

        while (@import("main.zig").c.sqlite3_step(stmt) == @import("main.zig").c.SQLITE_ROW) {
            const install_path_c = @import("main.zig").c.sqlite3_column_text(stmt, 0);
            if (install_path_c != null) {
                const ip = std.mem.span(install_path_c);
                std.fs.cwd().deleteFile(ip) catch {};
                // Also remove .shim file on windows
                const builtin = @import("builtin");
                if (builtin.os.tag == .windows) {
                    if (std.mem.endsWith(u8, ip, ".exe")) {
                        const shim_path = try std.fmt.allocPrint(allocator, "{s}.shim", .{ip[0 .. ip.len - 4]});
                        defer allocator.free(shim_path);
                        std.fs.cwd().deleteFile(shim_path) catch {};
                    }
                }
            }
        }
        _ = @import("main.zig").c.sqlite3_finalize(stmt);
    }

    const del_query = "DELETE FROM installed_packages WHERE name = ? AND version = ?";
    if (@import("main.zig").c.sqlite3_prepare_v2(db_conn.db, del_query, -1, &stmt, null) == @import("main.zig").c.SQLITE_OK) {
        _ = @import("main.zig").c.sqlite3_bind_text(stmt, 1, id_z.ptr, -1, @import("main.zig").c.SQLITE_STATIC);
        _ = @import("main.zig").c.sqlite3_bind_text(stmt, 2, version_z.ptr, -1, @import("main.zig").c.SQLITE_STATIC);
        _ = @import("main.zig").c.sqlite3_step(stmt);
        _ = @import("main.zig").c.sqlite3_finalize(stmt);
    }

    try hooks.runHook(allocator, db_conn, .post_uninstall, id, version, skip_prompts);
}
