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
        try std.zip.extract(out_dir, file.seekableStream(), .{});
        return true;
    } else if (std.ascii.endsWithIgnoreCase(original_url, ".tar.gz") or std.ascii.endsWithIgnoreCase(original_url, ".tgz")) {
        var gzip_stream = std.compress.gzip.decompressor(file.reader());
        try std.tar.pipeToFileSystem(out_dir, gzip_stream.reader(), .{ .mode_mode = .executable_bit_only });
        return true;
    } else if (std.ascii.endsWithIgnoreCase(original_url, ".tar.xz") or std.ascii.endsWithIgnoreCase(original_url, ".txz")) {
        var xz_stream = try std.compress.xz.decompress(allocator, file.reader());
        defer xz_stream.deinit();
        try std.tar.pipeToFileSystem(out_dir, xz_stream.reader(), .{ .mode_mode = .executable_bit_only });
        return true;
    } else if (std.ascii.endsWithIgnoreCase(original_url, ".tar")) {
        try std.tar.pipeToFileSystem(out_dir, file.reader(), .{ .mode_mode = .executable_bit_only });
        return true;
    }
    
    // Zig 0.13.0 standard library does not natively support bzip2.
    // If it's .tar.bz2 or unrecognized, return false so we fallback to system tar.
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
