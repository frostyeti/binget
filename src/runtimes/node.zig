const std = @import("std");
const core = @import("../core.zig");
const db = @import("../db.zig");
const install_cmd = @import("../install_cmd.zig");
const registry = @import("../registry.zig");
const builtin = @import("builtin");

pub fn install(allocator: std.mem.Allocator, db_conn: db.Database, version_opt: ?[]const u8, mode: install_cmd.InstallMode) !void {
    std.debug.print("Resolving builtin runtime 'node'...\n", .{});

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const url = "https://nodejs.org/dist/index.json";
    
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();
    var server_header_buffer: [8192]u8 = undefined;
    var res = try req.receiveHead(&server_header_buffer);

    if (res.head.status != .ok) {
        std.debug.print("Failed to fetch node versions\n", .{});
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
    var node_version_str: []const u8 = undefined; // e.g. "v20.0.0"
    
    if (version_opt) |v| {
        target_version = v;
        if (std.mem.startsWith(u8, v, "v")) {
            node_version_str = try allocator.dupe(u8, v);
            target_version = v[1..];
        } else {
            node_version_str = try std.fmt.allocPrint(allocator, "v{s}", .{v});
        }
    } else {
        // Just take the first one (latest stable)
        if (root.items.len == 0) return error.VersionNotFound;
        node_version_str = try allocator.dupe(u8, root.items[0].object.get("version").?.string);
        target_version = node_version_str[1..]; // Remove 'v'
    }
    defer {
        allocator.free(node_version_str);
    }
    
    std.debug.print("Target Node.js version: {s}\n", .{target_version});

    // Find the version object
    var version_obj: ?std.json.ObjectMap = null;
    for (root.items) |item| {
        const obj = item.object;
        if (std.mem.eql(u8, obj.get("version").?.string, node_version_str)) {
            version_obj = obj;
            break;
        }
    }
    
    if (version_obj == null) {
        std.debug.print("Version {s} not found.\n", .{node_version_str});
        return error.VersionNotFound;
    }

    const arch_str = switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        .arm => "armv7l",
        .powerpc64le => "ppc64le",
        .s390x => "s390x",
        .x86 => "x86",
        else => return error.UnsupportedArch,
    };
    
    const os_prefix = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "osx",
        .windows => "win",
        .aix => "aix",
        else => return error.UnsupportedOS,
    };

    const os_dl_str = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "darwin",
        .windows => "win",
        .aix => "aix",
        else => return error.UnsupportedOS,
    };

    const ext = switch (builtin.os.tag) {
        .windows => "zip",
        else => "tar.gz",
    };

    const ext_idx = switch (builtin.os.tag) {
        .windows => "-zip",
        .macos => "-tar",
        else => "",
    };

    const expected_file_key = try std.fmt.allocPrint(allocator, "{s}-{s}{s}", .{os_prefix, arch_str, ext_idx});
    defer allocator.free(expected_file_key);
    
    const files = version_obj.?.get("files").?.array;
    var found_platform = false;
    for (files.items) |file_val| {
        if (std.mem.eql(u8, file_val.string, expected_file_key)) {
            found_platform = true;
            break;
        }
    }
    
    if (!found_platform) {
        std.debug.print("Platform {s} not found for version {s}.\n", .{expected_file_key, node_version_str});
        return error.PlatformNotFound;
    }

    const filename = try std.fmt.allocPrint(allocator, "node-{s}-{s}-{s}.{s}", .{node_version_str, os_dl_str, arch_str, ext});
    defer allocator.free(filename);
    
    const tarball_url = try std.fmt.allocPrint(allocator, "https://nodejs.org/dist/{s}/{s}", .{node_version_str, filename});
    defer allocator.free(tarball_url);

    // Fetch SHASUMS256.txt to get the checksum
    const shasum_url = try std.fmt.allocPrint(allocator, "https://nodejs.org/dist/{s}/SHASUMS256.txt", .{node_version_str});
    defer allocator.free(shasum_url);

    const shasum_uri = try std.Uri.parse(shasum_url);
    var shasum_req = try client.request(.GET, shasum_uri, .{});
    defer shasum_req.deinit();

    try shasum_req.sendBodiless();
    var shasum_server_header_buffer: [8192]u8 = undefined;
    var shasum_res = try shasum_req.receiveHead(&shasum_server_header_buffer);

    if (shasum_res.head.status != .ok) {
        std.debug.print("Failed to fetch SHASUMS256.txt\n", .{});
        return error.HttpFailed;
    }

    var shasum_transfer_buf: [8192]u8 = undefined;
    var shasum_decompress_buf: [65536]u8 = undefined;
    var shasum_decompress: std.http.Decompress = undefined;
    const shasum_body = try shasum_res.readerDecompressing(&shasum_transfer_buf, &shasum_decompress, &shasum_decompress_buf).allocRemaining(allocator, limit);
    defer allocator.free(shasum_body);

    var shasum: ?[]const u8 = null;
    var line_iter = std.mem.splitScalar(u8, shasum_body, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.indexOf(u8, line, filename)) |_| {
            var parts = std.mem.splitScalar(u8, line, ' ');
            const hash = parts.first();
            shasum = try allocator.dupe(u8, hash);
            break;
        }
    }

    if (shasum == null) {
        std.debug.print("Checksum not found for {s}\n", .{filename});
        return error.ChecksumNotFound;
    }
    defer allocator.free(shasum.?);

    var bins = try allocator.alloc([]const u8, 3);
    if (builtin.os.tag == .windows) {
        bins[0] = try allocator.dupe(u8, "node.exe");
        bins[1] = try allocator.dupe(u8, "npm.cmd");
        bins[2] = try allocator.dupe(u8, "npx.cmd");
    } else {
        bins[0] = try allocator.dupe(u8, "bin/node");
        bins[1] = try allocator.dupe(u8, "bin/npm");
        bins[2] = try allocator.dupe(u8, "bin/npx");
    }
    defer {
        allocator.free(bins[0]);
        allocator.free(bins[1]);
        allocator.free(bins[2]);
        allocator.free(bins);
    }
    
    // Extracted directory name inside the archive is the filename without extension
    const extract_dir = try std.fmt.allocPrint(allocator, "node-{s}-{s}-{s}", .{node_version_str, os_dl_str, arch_str});
    defer allocator.free(extract_dir);

    const config = registry.InstallModeConfig{
        .type = try allocator.dupe(u8, "archive"),
        .url = try allocator.dupe(u8, tarball_url),
        .checksum = try allocator.dupe(u8, shasum.?),
        .extract_dir = try allocator.dupe(u8, extract_dir),
        .bin = bins,
    };
    defer {
        allocator.free(config.type);
        allocator.free(config.url.?);
        allocator.free(config.checksum.?);
        allocator.free(config.extract_dir.?);
    }
    
    std.debug.print("Downloading Node.js from {s}...\n", .{tarball_url});
    
    try core.executeRuntimeInstall(allocator, db_conn, "node", target_version, config, mode);
}
