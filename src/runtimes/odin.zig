const std = @import("std");
const core = @import("../core.zig");
const db = @import("../db.zig");
const install_cmd = @import("../install_cmd.zig");
const registry = @import("../registry.zig");
const builtin = @import("builtin");

pub fn install(allocator: std.mem.Allocator, db_conn: db.Database, version_opt: ?[]const u8, mode: install_cmd.InstallMode) !void {
    std.debug.print("Resolving builtin runtime 'odin'...\n", .{});

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var target_version: []const u8 = undefined;

    if (version_opt) |v| {
        target_version = try allocator.dupe(u8, v);
    } else {
        const url = "https://github.com/odin-lang/Odin/releases/latest";
        const uri = try std.Uri.parse(url);

        var req = try client.request(.GET, uri, .{ .redirect_behavior = .unhandled });
        defer req.deinit();

        try req.sendBodiless();
        var server_header_buffer: [8192]u8 = undefined;
        const res = try req.receiveHead(&server_header_buffer);

        if (res.head.status != .found and res.head.status != .see_other) {
            std.debug.print("Failed to find latest odin release (status {d})\n", .{res.head.status});
            return error.HttpFailed;
        }

        const location = res.head.location orelse return error.MissingLocationHeader;

        const tag_prefix = "/tag/";
        if (std.mem.lastIndexOf(u8, location, tag_prefix)) |idx| {
            target_version = try allocator.dupe(u8, location[idx + tag_prefix.len ..]);
        } else {
            return error.InvalidLocationHeader;
        }
    }
    defer allocator.free(target_version);

    std.debug.print("Target odin version: {s}\n", .{target_version});

    const arch_str = switch (builtin.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        else => return error.UnsupportedArch,
    };

    const os_str = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => return error.UnsupportedOS,
    };

    const ext = switch (builtin.os.tag) {
        .windows => "zip",
        else => "tar.gz",
    };

    const filename = try std.fmt.allocPrint(allocator, "odin-{s}-{s}-{s}.{s}", .{ os_str, arch_str, target_version, ext });
    defer allocator.free(filename);

    const download_url = try std.fmt.allocPrint(allocator, "https://github.com/odin-lang/Odin/releases/download/{s}/{s}", .{ target_version, filename });
    defer allocator.free(download_url);

    var bins = try allocator.alloc([]const u8, 1);
    if (builtin.os.tag == .windows) {
        bins[0] = try allocator.dupe(u8, "odin.exe");
    } else {
        bins[0] = try allocator.dupe(u8, "odin");
    }
    defer {
        allocator.free(bins[0]);
        allocator.free(bins);
    }

    const extract_dir = try std.fmt.allocPrint(allocator, "odin-{s}-{s}-{s}", .{ os_str, arch_str, target_version });
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

    std.debug.print("Downloading odin from {s}...\n", .{download_url});

    try core.executeRuntimeInstall(allocator, db_conn, "odin", target_version, config, mode);
}
