const std = @import("std");
const platform = @import("platform.zig");

pub fn getTrustedDirsPath(allocator: std.mem.Allocator) ![]const u8 {
    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);
    try std.fs.cwd().makePath(share_dir);
    return try std.fs.path.join(allocator, &.{ share_dir, "trusted_dirs" });
}

pub fn isTrusted(allocator: std.mem.Allocator, dir: []const u8) !bool {
    const trusted_path = try getTrustedDirsPath(allocator);
    defer allocator.free(trusted_path);

    var file = std.fs.cwd().openFile(trusted_path, .{}) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1 * 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (std.mem.eql(u8, trimmed, dir)) {
            return true;
        }
    }
    return false;
}

pub fn trustCurrentDir(allocator: std.mem.Allocator) !void {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    if (try isTrusted(allocator, cwd)) {
        std.debug.print("Directory is already trusted: {s}\n", .{cwd});
        return;
    }

    const trusted_path = try getTrustedDirsPath(allocator);
    defer allocator.free(trusted_path);

    var file = try std.fs.cwd().createFile(trusted_path, .{ .read = true, .truncate = false });
    defer file.close();
    
    try file.seekFromEnd(0);
    const line = try std.fmt.allocPrint(allocator, "{s}\n", .{cwd});
    defer allocator.free(line);
    try file.writeAll(line);

    std.debug.print("Trusted directory: {s}\n", .{cwd});
}
