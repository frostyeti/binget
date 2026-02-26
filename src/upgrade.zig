const std = @import("std");
const db = @import("db.zig");
const hooks = @import("hooks.zig");

pub fn upgradePackage(allocator: std.mem.Allocator, db_conn: db.Database, target: []const u8, global: bool, skip_prompts: bool) !void {
    _ = global; // In the future, differentiate between user and global installations

    var parts = std.mem.splitScalar(u8, target, '@');
    const id = parts.next().?;
    var version: ?[]const u8 = parts.next();
    var need_free_version = false;

    if (version == null) {
        const id_z = try allocator.dupeZ(u8, id);
        defer allocator.free(id_z);
        if (try db_conn.getInstalledVersion(allocator, id_z)) |v| {
            version = v;
            need_free_version = true;
        }
    }

    defer {
        if (need_free_version) {
            if (version) |v| allocator.free(v);
        }
    }

    std.debug.print("Upgrading {s}...\n", .{id});

    try hooks.runHook(allocator, db_conn, .pre_upgrade, id, version, skip_prompts);

    // Core upgrade logic would go here
    // e.g. finding the latest version, fetching it, swapping shims, etc.

    try hooks.runHook(allocator, db_conn, .post_upgrade, id, version, skip_prompts);
}
