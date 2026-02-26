const std = @import("std");
const core = @import("../core.zig");
const db = @import("../db.zig");
const install_cmd = @import("../install_cmd.zig");
const registry = @import("../registry.zig");
const builtin = @import("builtin");

pub fn install(allocator: std.mem.Allocator, db_conn: db.Database, version_opt: ?[]const u8, mode: install_cmd.InstallMode) !void {
    std.debug.print("Resolving builtin runtime 'uv'...\n", .{});

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var target_version: []const u8 = undefined;

    if (version_opt) |v| {
        if (std.mem.startsWith(u8, v, "v")) {
            target_version = try allocator.dupe(u8, v[1..]);
        } else {
            target_version = try allocator.dupe(u8, v);
        }
    } else {
        const url = "https://github.com/astral-sh/uv/releases/latest";
        const uri = try std.Uri.parse(url);

        // We use unhandled redirect behavior to just read the Location header
        var req = try client.request(.GET, uri, .{ .redirect_behavior = .unhandled });
        defer req.deinit();

        try req.sendBodiless();
        var server_header_buffer: [8192]u8 = undefined;
        const res = try req.receiveHead(&server_header_buffer);

        if (res.head.status != .found and res.head.status != .see_other) {
            std.debug.print("Failed to find latest uv release (status {d})\n", .{res.head.status});
            return error.HttpFailed;
        }

        const location = res.head.location orelse return error.MissingLocationHeader;

        // location usually looks like https://github.com/astral-sh/uv/releases/tag/0.1.20
        const tag_prefix = "/tag/";
        if (std.mem.lastIndexOf(u8, location, tag_prefix)) |idx| {
            const v_str = location[idx + tag_prefix.len ..];
            if (std.mem.startsWith(u8, v_str, "v")) {
                target_version = try allocator.dupe(u8, v_str[1..]);
            } else {
                target_version = try allocator.dupe(u8, v_str);
            }
        } else {
            return error.InvalidLocationHeader;
        }
    }
    defer allocator.free(target_version);

    std.debug.print("Target uv version: {s}\n", .{target_version});

    const arch_str = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "i686",
        .arm => "armv7",
        .powerpc64le => "powerpc64le",
        else => return error.UnsupportedArch,
    };

    const os_str = switch (builtin.os.tag) {
        .linux => "unknown-linux-gnu",
        .macos => "apple-darwin",
        .windows => "pc-windows-msvc",
        else => return error.UnsupportedOS,
    };

    const target_triple = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ arch_str, os_str });
    defer allocator.free(target_triple);

    const ext = switch (builtin.os.tag) {
        .windows => "zip",
        else => "tar.gz",
    };

    const filename = try std.fmt.allocPrint(allocator, "uv-{s}.{s}", .{ target_triple, ext });
    defer allocator.free(filename);

    const download_url = try std.fmt.allocPrint(allocator, "https://github.com/astral-sh/uv/releases/download/{s}/{s}", .{ target_version, filename });
    defer allocator.free(download_url);

    var bins = try allocator.alloc([]const u8, 2);
    if (builtin.os.tag == .windows) {
        bins[0] = try allocator.dupe(u8, "uv.exe");
        bins[1] = try allocator.dupe(u8, "uvx.exe");
    } else {
        bins[0] = try allocator.dupe(u8, "uv");
        bins[1] = try allocator.dupe(u8, "uvx");
    }
    defer {
        allocator.free(bins[0]);
        allocator.free(bins[1]);
        allocator.free(bins);
    }

    const extract_dir = try std.fmt.allocPrint(allocator, "uv-{s}", .{target_triple});
    defer allocator.free(extract_dir);

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

    std.debug.print("Downloading uv from {s}...\n", .{download_url});

    try core.executeRuntimeInstall(allocator, db_conn, "uv", target_version, config, mode);
}
