const std = @import("std");

pub fn downloadFile(allocator: std.mem.Allocator, url: []const u8, out_path: []const u8) !void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var server_header_buffer: [8192]u8 = undefined;

    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buffer,
    });
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        if (req.response.status == .found or req.response.status == .see_other or req.response.status == .temporary_redirect) {
            // Find Location header manually in Zig 0.13
            var iter = req.response.iterateHeaders();
            while (iter.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "location")) {
                    return downloadFile(allocator, header.value, out_path);
                }
            }
        }
        std.debug.print("Download failed with status {}\n", .{req.response.status});
        return error.HttpFailed;
    }

    var file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();

    var buffer: [8192]u8 = undefined;
    while (true) {
        const bytes_read = try req.reader().read(&buffer);
        if (bytes_read == 0) break;
        try file.writeAll(buffer[0..bytes_read]);
    }
}

pub fn extractArchive(allocator: std.mem.Allocator, archive_path: []const u8, out_dir: []const u8) !void {
    // Ensure out_dir exists
    try std.fs.cwd().makePath(out_dir);

    // Use system tar. Windows 10+ has tar natively that supports zip and tar.gz.
    const argv = &[_][]const u8{ "tar", "-xf", archive_path, "-C", out_dir };

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("tar exited with code {}\n", .{code});
                return error.ExtractFailed;
            }
        },
        else => return error.ExtractFailed,
    }
}

pub fn makeExecutable(path: []const u8) !void {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) {
        var file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        defer file.close();
        const stat = try file.stat();
        // Add execute bit for user, group, and others
        try file.chmod(stat.mode | 0o111);
    }
}
