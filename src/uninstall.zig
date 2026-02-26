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

    // Core uninstall logic would go here
    // e.g. deleting from DB, removing files/shims, etc.

    try hooks.runHook(allocator, db_conn, .post_uninstall, id, version, skip_prompts);
}
