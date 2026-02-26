const std = @import("std");
const core = @import("../core.zig");
const db = @import("../db.zig");
const install_cmd = @import("../install_cmd.zig");
const registry = @import("../registry.zig");
const builtin = @import("builtin");

pub fn install(allocator: std.mem.Allocator, db_conn: db.Database, version_opt: ?[]const u8, mode: install_cmd.InstallMode) !void {
    std.debug.print("Resolving builtin runtime 'dotnet'...\n", .{});

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var target_version: []const u8 = undefined;

    // Check if version_opt is a channel (e.g. "8.0", "9.0") or a specific SDK version (e.g. "8.0.200")
    // Or if null, we find the latest active.
    var needs_resolution = true;
    if (version_opt) |v| {
        if (std.mem.count(u8, v, ".") >= 2) {
            target_version = try allocator.dupe(u8, v);
            needs_resolution = false;
        }
    }

    if (needs_resolution) {
        const url = "https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json";
        
        const uri = try std.Uri.parse(url);
        var req = try client.request(.GET, uri, .{});
        defer req.deinit();

        try req.sendBodiless();
        var server_header_buffer: [8192]u8 = undefined;
        var res = try req.receiveHead(&server_header_buffer);

        if (res.head.status != .ok) {
            std.debug.print("Failed to fetch dotnet releases index\n", .{});
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
        const releases_index = root.get("releases-index").?.array;
        
        var found_sdk: ?[]const u8 = null;
        
        for (releases_index.items) |item| {
            const obj = item.object;
            const channel = obj.get("channel-version").?.string;
            const sdk = obj.get("latest-sdk").?.string;
            const support = obj.get("support-phase").?.string;
            
            if (version_opt) |v| {
                if (std.mem.eql(u8, channel, v)) {
                    found_sdk = sdk;
                    break;
                }
            } else {
                if (std.mem.eql(u8, support, "active") or std.mem.eql(u8, support, "maintenance")) {
                    found_sdk = sdk;
                    break;
                }
            }
        }
        
        if (found_sdk == null) {
            std.debug.print("Could not resolve dotnet version.\n", .{});
            return error.VersionNotFound;
        }
        
        target_version = try allocator.dupe(u8, found_sdk.?);
    }
    defer allocator.free(target_version);
    
    std.debug.print("Target Dotnet SDK version: {s}\n", .{target_version});

    const arch_str = switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        .arm => "arm",
        .x86 => "x86",
        else => return error.UnsupportedArch,
    };
    
    const os_target = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "osx",
        .windows => "win",
        else => return error.UnsupportedOS,
    };

    const ext = switch (builtin.os.tag) {
        .windows => "zip",
        else => "tar.gz",
    };

    const filename = try std.fmt.allocPrint(allocator, "dotnet-sdk-{s}-{s}-{s}.{s}", .{target_version, os_target, arch_str, ext});
    defer allocator.free(filename);
    
    const tarball_url = try std.fmt.allocPrint(allocator, "https://dotnetcli.azureedge.net/dotnet/Sdk/{s}/{s}", .{target_version, filename});
    defer allocator.free(tarball_url);

    var bins = try allocator.alloc([]const u8, 1);
    bins[0] = try allocator.dupe(u8, if (builtin.os.tag == .windows) "dotnet.exe" else "dotnet");
    defer {
        allocator.free(bins[0]);
        allocator.free(bins);
    }
    
    const config = registry.InstallModeConfig{
        .type = try allocator.dupe(u8, "archive"),
        .url = try allocator.dupe(u8, tarball_url),
        .checksum = null,
        .extract_dir = try allocator.dupe(u8, ""), // dotnet extracts straight into the root
        .bin = bins,
    };
    defer {
        allocator.free(config.type);
        allocator.free(config.url.?);
        allocator.free(config.extract_dir.?);
    }
    
    std.debug.print("Downloading Dotnet from {s}...\n", .{tarball_url});
    
    try core.executeRuntimeInstall(allocator, db_conn, "dotnet", target_version, config, mode);
}
