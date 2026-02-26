const std = @import("std");
const core = @import("../core.zig");
const db = @import("../db.zig");
const install_cmd = @import("../install_cmd.zig");
const registry = @import("../registry.zig");
const builtin = @import("builtin");

pub fn install(allocator: std.mem.Allocator, db_conn: db.Database, version_opt: ?[]const u8, mode: install_cmd.InstallMode) !void {
    std.debug.print("Resolving builtin runtime 'zig'...\n", .{});

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse("https://ziglang.org/download/index.json");
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();
    var server_header_buffer: [8192]u8 = undefined;
    var res = try req.receiveHead(&server_header_buffer);

    if (res.head.status != .ok) {
        std.debug.print("Failed to fetch ziglang.org/download/index.json\n", .{});
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

    const root = parsed.value.object;
    
    var target_version: []const u8 = undefined;
    
    if (version_opt) |v| {
        target_version = v;
    } else {
        // Find latest stable
        var latest: ?[]const u8 = null;
        var it = root.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "master")) continue;
            // The JSON from Zig preserves some order usually, but to be safe we just parse SemanticVersion
            if (latest == null) {
                latest = entry.key_ptr.*;
            } else {
                const current_ver = std.SemanticVersion.parse(latest.?) catch continue;
                const entry_ver = std.SemanticVersion.parse(entry.key_ptr.*) catch continue;
                if (entry_ver.order(current_ver) == .gt) {
                    latest = entry.key_ptr.*;
                }
            }
        }
        if (latest == null) return error.VersionNotFound;
        target_version = latest.?;
    }
    
    std.debug.print("Target Zig version: {s}\n", .{target_version});

    const version_obj = root.get(target_version) orelse {
        std.debug.print("Version {s} not found.\n", .{target_version});
        return error.VersionNotFound;
    };

    const arch_str = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "armv7a",
        .powerpc64le => "powerpc64le",
        .riscv64 => "riscv64",
        .x86 => "x86",
        else => return error.UnsupportedArch,
    };
    
    const os_str = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        .freebsd => "freebsd",
        else => return error.UnsupportedOS,
    };
    
    const platform_key = try std.fmt.allocPrint(allocator, "{s}-{s}", .{arch_str, os_str});
    defer allocator.free(platform_key);
    
    const platform_obj = version_obj.object.get(platform_key) orelse {
        std.debug.print("Platform {s} not found for version {s}.\n", .{platform_key, target_version});
        return error.PlatformNotFound;
    };
    
    const tarball_url = platform_obj.object.get("tarball").?.string;
    const shasum = platform_obj.object.get("shasum").?.string;

    // determine extract_dir from URL by removing .tar.xz or .zip
    const basename = std.fs.path.basename(tarball_url);
    var ext_len: usize = 0;
    if (std.mem.endsWith(u8, basename, ".tar.xz")) {
        ext_len = 7;
    } else if (std.mem.endsWith(u8, basename, ".zip")) {
        ext_len = 4;
    }
    const extract_dir = basename[0 .. basename.len - ext_len];

    var bins = try allocator.alloc([]const u8, 1);
    bins[0] = try allocator.dupe(u8, if (builtin.os.tag == .windows) "zig.exe" else "zig");
    defer {
        allocator.free(bins[0]);
        allocator.free(bins);
    }
    
    const config = registry.InstallModeConfig{
        .type = try allocator.dupe(u8, "archive"),
        .url = try allocator.dupe(u8, tarball_url),
        .checksum = try allocator.dupe(u8, shasum),
        .extract_dir = try allocator.dupe(u8, extract_dir),
        .bin = bins,
    };
    defer {
        allocator.free(config.type);
        allocator.free(config.url.?);
        allocator.free(config.checksum.?);
        allocator.free(config.extract_dir.?);
    }
    
    std.debug.print("Downloading Zig from {s}...\n", .{tarball_url});
    
    try core.executeRuntimeInstall(allocator, db_conn, "zig", target_version, config, mode);
}