const std = @import("std");
const core = @import("../core.zig");
const db = @import("../db.zig");
const install_cmd = @import("../install_cmd.zig");
const registry = @import("../registry.zig");
const builtin = @import("builtin");

pub fn install(allocator: std.mem.Allocator, db_conn: db.Database, version_opt: ?[]const u8, mode: install_cmd.InstallMode) !void {
    std.debug.print("Resolving builtin runtime 'ruby'...\n", .{});

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var target_version: []const u8 = undefined;

    if (version_opt) |v| {
        target_version = try allocator.dupe(u8, v);
    } else {
        const url = "https://github.com/jdx/ruby/releases/latest";
        const uri = try std.Uri.parse(url);

        var req = try client.request(.GET, uri, .{ .redirect_behavior = .unhandled });
        defer req.deinit();

        try req.sendBodiless();
        var server_header_buffer: [8192]u8 = undefined;
        const res = try req.receiveHead(&server_header_buffer);

        if (res.head.status != .found and res.head.status != .see_other) {
            std.debug.print("Failed to find latest ruby release (status {d})\n", .{res.head.status});
            return error.HttpFailed;
        }

        const location = res.head.location orelse return error.MissingLocationHeader;

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

    std.debug.print("Target Ruby version: {s}\n", .{target_version});

    var platform_str: []const u8 = undefined;
    if (builtin.os.tag == .linux) {
        if (builtin.cpu.arch == .x86_64) {
            platform_str = "x86_64_linux";
        } else if (builtin.cpu.arch == .aarch64) {
            platform_str = "arm64_linux";
        } else {
            return error.UnsupportedArch;
        }
    } else if (builtin.os.tag == .macos) {
        if (builtin.cpu.arch == .aarch64) {
            platform_str = "macos";
        } else {
            return error.UnsupportedArch; // x86_64 macos not precompiled by jdx/ruby currently
        }
    } else {
        return error.UnsupportedOS;
    }

    const filename = try std.fmt.allocPrint(allocator, "ruby-{s}.{s}.tar.gz", .{ target_version, platform_str });
    defer allocator.free(filename);

    const download_url = try std.fmt.allocPrint(allocator, "https://github.com/jdx/ruby/releases/download/{s}/{s}", .{ target_version, filename });
    defer allocator.free(download_url);

    var bins = try allocator.alloc([]const u8, 3);
    bins[0] = try allocator.dupe(u8, "bin/ruby");
    bins[1] = try allocator.dupe(u8, "bin/gem");
    bins[2] = try allocator.dupe(u8, "bin/irb");
    defer {
        allocator.free(bins[0]);
        allocator.free(bins[1]);
        allocator.free(bins[2]);
        allocator.free(bins);
    }

    const extract_dir = try std.fmt.allocPrint(allocator, "ruby-{s}", .{target_version});
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

    std.debug.print("Downloading Ruby from {s}...\n", .{download_url});

    try core.executeRuntimeInstall(allocator, db_conn, "ruby", target_version, config, mode);
}
