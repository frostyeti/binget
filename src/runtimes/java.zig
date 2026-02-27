const std = @import("std");
const core = @import("../core.zig");
const db = @import("../db.zig");
const install_cmd = @import("../install_cmd.zig");
const registry = @import("../registry.zig");
const builtin = @import("builtin");

pub fn install(allocator: std.mem.Allocator, db_conn: db.Database, version_opt: ?[]const u8, mode: install_cmd.InstallMode) !void {
    std.debug.print("Resolving builtin runtime 'java' (Eclipse Temurin)...\n", .{});

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var target_version: []const u8 = undefined;

    if (version_opt) |v| {
        target_version = try allocator.dupe(u8, v);
    } else {
        target_version = try allocator.dupe(u8, "21");
    }
    defer allocator.free(target_version);

    const arch_str = switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "aarch64",
        else => return error.UnsupportedArch,
    };

    const os_str = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "mac",
        .windows => "windows",
        else => return error.UnsupportedOS,
    };

    const url = try std.fmt.allocPrint(allocator, "https://api.adoptium.net/v3/assets/latest/{s}/hotspot?architecture={s}&image_type=jdk&os={s}", .{ target_version, arch_str, os_str });
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();
    var server_header_buffer: [8192]u8 = undefined;
    var res = try req.receiveHead(&server_header_buffer);

    if (res.head.status != .ok) {
        std.debug.print("Failed to fetch Java versions (status {d})\n", .{res.head.status});
        return error.HttpFailed;
    }

    var transfer_buf: [8192]u8 = undefined;
    var decompress_buf: [65536]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const limit: std.io.Limit = @enumFromInt(10 * 1024 * 1024);
    const body = try res.readerDecompressing(&transfer_buf, &decompress, &decompress_buf).allocRemaining(allocator, limit);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.array;
    if (root.items.len == 0) {
        std.debug.print("No Java releases found for this platform.\n", .{});
        return error.NoReleasesFound;
    }

    const first = root.items[0].object;
    const binary = first.get("binary").?.object;
    const pkg = binary.get("package").?.object;
    const download_url = pkg.get("link").?.string;
    const release_name = first.get("release_name").?.string;
    const package_name = pkg.get("name").?.string;

    std.debug.print("Target Java version: {s}\n", .{release_name});

    var bins = try allocator.alloc([]const u8, 1);
    if (builtin.os.tag == .windows) {
        bins[0] = try allocator.dupe(u8, "bin/java.exe");
    } else {
        bins[0] = try allocator.dupe(u8, "bin/java");
    }
    defer {
        allocator.free(bins[0]);
        allocator.free(bins);
    }

    // Extract directory depends on the OS. Temurin generally creates `jdk-21.0.10+7` but we need to verify.
    // Actually, archive.zig handles extracting, but core.executeRuntimeInstall uses config.extract_dir.
    // Wait, let's see what `node.zig` or `python.zig` use for extract_dir.
    // They usually do `try allocator.dupe(u8, package_name[0 .. package_name.len - ext.len])`

    // We'll strip .tar.gz or .zip from package_name
    var extract_dir_name: []const u8 = undefined;
    if (std.mem.endsWith(u8, package_name, ".zip")) {
        extract_dir_name = package_name[0 .. package_name.len - 4];
    } else if (std.mem.endsWith(u8, package_name, ".tar.gz")) {
        extract_dir_name = package_name[0 .. package_name.len - 7];
    } else {
        extract_dir_name = package_name;
    }

    // Actually the tarball extract directory is usually `jdk-21.0.10+7` on mac/linux but on Mac it might be `jdk-21.0.10+7/Contents/Home/bin/java`.
    // Let's print out the exact `extract_dir` we think it should be.
    // Better yet, Adoptium extracts to `jdk-<version>`. E.g., `jdk-21.0.10+7`. Wait, the release name is exactly that!

    const extract_dir = try allocator.dupe(u8, release_name);
    // On Mac, Temurin extracts to `jdk-21.0.10+7/Contents/Home`!
    // So on mac, we need to adjust the bin path: `Contents/Home/bin/java`.

    if (builtin.os.tag == .macos) {
        allocator.free(bins[0]);
        bins[0] = try allocator.dupe(u8, "Contents/Home/bin/java");
    }

    const config = registry.InstallModeConfig{
        .type = try allocator.dupe(u8, "archive"),
        .url = try allocator.dupe(u8, download_url),
        .checksum = null,
        .extract_dir = try allocator.dupe(u8, extract_dir),
        .bin = bins,
    };
    defer {
        allocator.free(config.type);
        allocator.free(config.url.?);
        allocator.free(config.extract_dir.?);
    }

    std.debug.print("Downloading java from {s}...\n", .{download_url});

    try core.executeRuntimeInstall(allocator, db_conn, "java", target_version, config, mode);
}
