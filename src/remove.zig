const std = @import("std");
const env = @import("env.zig");

const remove_help =
    \\Remove a package from the local .binget.
    \\
    \\Usage:
    \\  binget remove <name>
    \\  binget remove -h | --help
    \\
    \\Options:
    \\  -h, --help       Show this help message and exit
    \\
;

pub fn parseAndRun(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 3 or std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help")) {
        std.debug.print("{s}", .{remove_help});
        return;
    }

    const target = args[2];

    const config_path = try env.findConfig(allocator) orelse {
        std.debug.print("Error: No .binget found.\n", .{});
        return error.NoConfigFound;
    };
    defer allocator.free(config_path);

    var file = try std.fs.cwd().openFile(config_path, .{ .mode = .read_write });
    defer file.close();

    const stat = try file.stat();
    const content = try file.readToEndAlloc(allocator, @intCast(stat.size));
    defer allocator.free(content);

    var new_content = std.ArrayList(u8).empty;
    defer new_content.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var found = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        // Naive match: if line contains target as first word, ignore it
        if (trimmed.len > 0 and std.mem.startsWith(u8, trimmed, target)) {
            found = true;
            continue;
        }
        try new_content.appendSlice(allocator, line);
        try new_content.append(allocator, '\n');
    }

    if (found) {
        // truncate and write
        try file.seekTo(0);
        try file.setEndPos(0);
        try file.writeAll(new_content.items);
        std.debug.print("Removed {s} from {s}\n", .{ target, config_path });

        // Also uninstall it

        const share_dir = try @import("platform.zig").getBingetShareDir(allocator);
        defer allocator.free(share_dir);
        const real_db_path = try std.fs.path.join(allocator, &.{ share_dir, "binget.db" });
        defer allocator.free(real_db_path);

        const db_path_z = try allocator.dupeZ(u8, real_db_path);
        defer allocator.free(db_path_z);
        var db_conn = try @import("db.zig").Database.open(db_path_z);
        defer db_conn.close();

        @import("uninstall.zig").uninstallPackage(allocator, db_conn, target, false) catch |err| {
            std.debug.print("Note: Could not uninstall {s}: {}\n", .{ target, err });
        };
    } else {
        std.debug.print("{s} not found in {s}\n", .{ target, config_path });
    }
}
