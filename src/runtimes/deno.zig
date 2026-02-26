const std = @import("std");
const core = @import("../core.zig");
const db = @import("../db.zig");
const install_cmd = @import("../install_cmd.zig");
const registry = @import("../registry.zig");
const builtin = @import("builtin");

pub fn install(allocator: std.mem.Allocator, db_conn: db.Database, version_opt: ?[]const u8, mode: install_cmd.InstallMode) !void {
    std.debug.print("Resolving builtin runtime 'deno'...\n", .{});

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var target_version: []const u8 = undefined;
    var deno_version_str: []const u8 = undefined;

    if (version_opt) |v| {
        target_version = v;
        if (std.mem.startsWith(u8, v, "v")) {
            deno_version_str = try allocator.dupe(u8, v);
            target_version = v[1..];
        } else {
            deno_version_str = try std.fmt.allocPrint(allocator, "v{s}", .{v});
        }
    } else {
        const url = "https://dl.deno.land/release-latest.txt";
        
        const uri = try std.Uri.parse(url);
        var req = try client.request(.GET, uri, .{});
        defer req.deinit();

        try req.sendBodiless();
        var server_header_buffer: [8192]u8 = undefined;
        var res = try req.receiveHead(&server_header_buffer);

        if (res.head.status != .ok) {
            std.debug.print("Failed to fetch latest deno version\n", .{});
            return error.HttpFailed;
        }

        var transfer_buf: [8192]u8 = undefined;
        const limit: std.io.Limit = @enumFromInt(1024);
        const body = try res.reader(&transfer_buf).allocRemaining(allocator, limit);
        defer allocator.free(body);

        deno_version_str = try allocator.dupe(u8, std.mem.trim(u8, body, " \n\r"));
        if (std.mem.startsWith(u8, deno_version_str, "v")) {
            target_version = deno_version_str[1..];
        } else {
            target_version = deno_version_str;
        }
    }
    defer {
        allocator.free(deno_version_str);
    }
    
    std.debug.print("Target Deno version: {s}\n", .{target_version});

    const arch_str = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return error.UnsupportedArch,
    };
    
    const os_str = switch (builtin.os.tag) {
        .linux => "unknown-linux-gnu",
        .macos => "apple-darwin",
        .windows => "pc-windows-msvc",
        else => return error.UnsupportedOS,
    };

    const target_triple = try std.fmt.allocPrint(allocator, "{s}-{s}", .{arch_str, os_str});
    defer allocator.free(target_triple);

    const filename = try std.fmt.allocPrint(allocator, "deno-{s}.zip", .{target_triple});
    defer allocator.free(filename);
    
    const zip_url = try std.fmt.allocPrint(allocator, "https://dl.deno.land/release/{s}/{s}", .{deno_version_str, filename});
    defer allocator.free(zip_url);

    var bins = try allocator.alloc([]const u8, 1);
    bins[0] = try allocator.dupe(u8, if (builtin.os.tag == .windows) "deno.exe" else "deno");
    defer {
        allocator.free(bins[0]);
        allocator.free(bins);
    }
    
    const config = registry.InstallModeConfig{
        .type = try allocator.dupe(u8, "archive"),
        .url = try allocator.dupe(u8, zip_url),
        .checksum = null,
        .extract_dir = try allocator.dupe(u8, ""), // extract into root
        .bin = bins,
    };
    defer {
        allocator.free(config.type);
        allocator.free(config.url.?);
        allocator.free(config.extract_dir.?);
    }
    
    std.debug.print("Downloading Deno from {s}...\n", .{zip_url});
    
    try core.executeRuntimeInstall(allocator, db_conn, "deno", target_version, config, mode);
}
