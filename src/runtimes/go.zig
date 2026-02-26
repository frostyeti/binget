const std = @import("std");
const core = @import("../core.zig");
const db = @import("../db.zig");
const install_cmd = @import("../install_cmd.zig");
const registry = @import("../registry.zig");
const builtin = @import("builtin");

pub fn install(allocator: std.mem.Allocator, db_conn: db.Database, version_opt: ?[]const u8, mode: install_cmd.InstallMode) !void {
    std.debug.print("Resolving builtin runtime 'go'...\n", .{});

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // If version is specified, we might need ?mode=json&include=all, otherwise just ?mode=json
    const url = if (version_opt != null) "https://go.dev/dl/?mode=json&include=all" else "https://go.dev/dl/?mode=json";

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();
    var server_header_buffer: [8192]u8 = undefined;
    var res = try req.receiveHead(&server_header_buffer);

    if (res.head.status != .ok) {
        std.debug.print("Failed to fetch go versions\n", .{});
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

    var target_version: []const u8 = undefined;
    var go_version_str: []const u8 = undefined; // e.g. "go1.21.0"

    if (version_opt) |v| {
        target_version = v;
        go_version_str = try std.fmt.allocPrint(allocator, "go{s}", .{v});
    } else {
        // Just take the first one (latest stable)
        if (root.items.len == 0) return error.VersionNotFound;
        go_version_str = try allocator.dupe(u8, root.items[0].object.get("version").?.string);
        // Remove "go" prefix for our internal tracking
        if (std.mem.startsWith(u8, go_version_str, "go")) {
            target_version = go_version_str[2..];
        } else {
            target_version = go_version_str;
        }
    }
    defer {
        if (version_opt != null) allocator.free(go_version_str);
        if (version_opt == null) allocator.free(go_version_str);
    }

    std.debug.print("Target Go version: {s}\n", .{target_version});

    // Find the version object
    var version_obj: ?std.json.ObjectMap = null;
    for (root.items) |item| {
        const obj = item.object;
        if (std.mem.eql(u8, obj.get("version").?.string, go_version_str)) {
            version_obj = obj;
            break;
        }
    }

    if (version_obj == null) {
        std.debug.print("Version {s} not found.\n", .{go_version_str});
        return error.VersionNotFound;
    }

    const arch_str = switch (builtin.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .arm => "armv6l", // mostly armv6l for go, but arm can be tricky
        .powerpc64le => "ppc64le",
        .riscv64 => "riscv64",
        .x86 => "386",
        else => return error.UnsupportedArch,
    };

    const os_str = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "darwin",
        .windows => "windows",
        .freebsd => "freebsd",
        else => return error.UnsupportedOS,
    };

    const files = version_obj.?.get("files").?.array;
    var target_file: ?std.json.ObjectMap = null;

    for (files.items) |file_val| {
        const file_obj = file_val.object;
        if (!std.mem.eql(u8, file_obj.get("os").?.string, os_str)) continue;
        if (!std.mem.eql(u8, file_obj.get("arch").?.string, arch_str)) continue;
        if (!std.mem.eql(u8, file_obj.get("kind").?.string, "archive")) continue;
        target_file = file_obj;
        break;
    }

    if (target_file == null) {
        std.debug.print("Platform {s}-{s} not found for version {s}.\n", .{ os_str, arch_str, go_version_str });
        return error.PlatformNotFound;
    }

    const filename = target_file.?.get("filename").?.string;
    const shasum = target_file.?.get("sha256").?.string;

    const tarball_url = try std.fmt.allocPrint(allocator, "https://dl.google.com/go/{s}", .{filename});
    defer allocator.free(tarball_url);

    var bins = try allocator.alloc([]const u8, 2);
    bins[0] = try allocator.dupe(u8, if (builtin.os.tag == .windows) "bin/go.exe" else "bin/go");
    bins[1] = try allocator.dupe(u8, if (builtin.os.tag == .windows) "bin/gofmt.exe" else "bin/gofmt");
    defer {
        allocator.free(bins[0]);
        allocator.free(bins[1]);
        allocator.free(bins);
    }

    const config = registry.InstallModeConfig{
        .type = try allocator.dupe(u8, "archive"),
        .url = try allocator.dupe(u8, tarball_url),
        .checksum = try allocator.dupe(u8, shasum),
        .extract_dir = try allocator.dupe(u8, "go"),
        .bin = bins,
    };
    defer {
        allocator.free(config.type);
        allocator.free(config.url.?);
        allocator.free(config.checksum.?);
        allocator.free(config.extract_dir.?);
    }

    std.debug.print("Downloading Go from {s}...\n", .{tarball_url});

    try core.executeRuntimeInstall(allocator, db_conn, "go", target_version, config, mode);
}
