const std = @import("std");
const ar = @import("ar.zig");

pub fn downloadFile(allocator: std.mem.Allocator, url: []const u8, out_path: []const u8) !void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var req = try client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5), // allow 5 redirects
    });
    defer req.deinit();

    try req.sendBodiless();
    
    var redirect_buf: [8192]u8 = undefined;
    var res = try req.receiveHead(&redirect_buf);

    if (res.head.status != .ok) {
        std.debug.print("Download failed with status {}\n", .{res.head.status});
        return error.HttpFailed;
    }

    var file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();
    var write_buf: [8192]u8 = undefined;
    var file_writer = file.writer(&write_buf);

    var transfer_buf: [8192]u8 = undefined;
    const downloaded_size = try res.reader(&transfer_buf).streamRemaining(&file_writer.interface);
    try file_writer.interface.flush();
    std.debug.print("Downloaded {} bytes.\n", .{downloaded_size});
}

pub fn extractArchive(allocator: std.mem.Allocator, archive_path: []const u8, out_dir_path: []const u8, original_url: []const u8) !void {
    try std.fs.cwd().makePath(out_dir_path);

    // Try native Zig extraction first
    if (try extractNative(allocator, archive_path, out_dir_path, original_url)) {
        return;
    }

    std.debug.print("Native extraction unsupported for this format, falling back to system tar...\n", .{});
    
    // Fallback to system tar
    const argv = &[_][]const u8{ "tar", "-xf", archive_path, "-C", out_dir_path };
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

fn extractNative(allocator: std.mem.Allocator, archive_path: []const u8, out_dir_path: []const u8, original_url: []const u8) !bool {
    var out_dir = try std.fs.cwd().openDir(out_dir_path, .{});
    defer out_dir.close();

    var file = try std.fs.cwd().openFile(archive_path, .{});
    defer file.close();

    if (std.ascii.endsWithIgnoreCase(original_url, ".zip")) {
        var read_buf: [8192]u8 = undefined;
        var file_reader = file.reader(&read_buf);
        try std.zip.extract(out_dir, &file_reader, .{});
        return true;
    } else if (std.ascii.endsWithIgnoreCase(original_url, ".deb")) {
        const ar_out = try std.fs.path.join(allocator, &.{ out_dir_path, "_data_tar_from_deb" });
        defer allocator.free(ar_out);

        if (try ar.extractArMemberByPrefix(archive_path, "data.tar", ar_out)) {
            const is_success = try extractNative(allocator, ar_out, out_dir_path, ar_out);
            std.fs.cwd().deleteFile(ar_out) catch {};
            return is_success;
        }
        return false;
    } else if (std.ascii.endsWithIgnoreCase(original_url, ".tar.gz") or std.ascii.endsWithIgnoreCase(original_url, ".tgz")) {
        var read_buf: [8192]u8 = undefined;
        var file_reader = file.reader(&read_buf);
        var decompress_buf: [65536]u8 = undefined;
        var gzip_stream = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, &decompress_buf);
        std.tar.pipeToFileSystem(out_dir, &gzip_stream.reader, .{ .mode_mode = .executable_bit_only }) catch |err| {
            std.debug.print("Native tar.gz extraction failed ({}), falling back to system tar...\n", .{err});
            return false;
        };
        return true;
    } else if (std.ascii.endsWithIgnoreCase(original_url, ".tar")) {
        var read_buf: [8192]u8 = undefined;
        var file_reader = file.reader(&read_buf);
        try std.tar.pipeToFileSystem(out_dir, &file_reader.interface, .{ .mode_mode = .executable_bit_only });
        return true;
    }
    
    // Fallback to system tar for xz, bzip2, etc.
    return false;
}

pub fn makeExecutable(path: []const u8) !void {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) {
        var file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        defer file.close();
        const stat = try file.stat();
        try file.chmod(stat.mode | 0o111);
    }
}
