const std = @import("std");
const core = @import("../core.zig");
const db = @import("../db.zig");
const install_cmd = @import("../install_cmd.zig");
const registry = @import("../registry.zig");
const builtin = @import("builtin");

pub fn install(allocator: std.mem.Allocator, db_conn: db.Database, version_opt: ?[]const u8, mode: install_cmd.InstallMode) !void {
    std.debug.print("Resolving builtin runtime 'rust'...\n", .{});

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var target_version: []const u8 = undefined;
    
    if (version_opt) |v| {
        target_version = try allocator.dupe(u8, v);
    } else {
        const url = "https://static.rust-lang.org/dist/channel-rust-stable.toml";
        
        const uri = try std.Uri.parse(url);
        var req = try client.request(.GET, uri, .{});
        defer req.deinit();

        try req.sendBodiless();
        var server_header_buffer: [8192]u8 = undefined;
        var res = try req.receiveHead(&server_header_buffer);

        if (res.head.status != .ok) {
            std.debug.print("Failed to fetch rust stable channel toml\n", .{});
            return error.HttpFailed;
        }

        var transfer_buf: [8192]u8 = undefined;
        var decompress_buf: [65536]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const limit: std.io.Limit = @enumFromInt(10 * 1024 * 1024);
        const body = try res.readerDecompressing(&transfer_buf, &decompress, &decompress_buf).allocRemaining(allocator, limit);
        defer allocator.free(body);

        // Very basic parsing for [pkg.rust] and version = "X.Y.Z ..."
        var found_pkg_rust = false;
        var version_str: ?[]const u8 = null;
        var line_iter = std.mem.splitScalar(u8, body, '\n');
        
        while (line_iter.next()) |line| {
            const t = std.mem.trim(u8, line, " \r");
            if (std.mem.eql(u8, t, "[pkg.rust]")) {
                found_pkg_rust = true;
                continue;
            }
            if (found_pkg_rust and std.mem.startsWith(u8, t, "version = \"")) {
                const start = t[11..];
                if (std.mem.indexOf(u8, start, " ")) |space_idx| {
                    version_str = start[0..space_idx];
                } else if (std.mem.indexOf(u8, start, "\"")) |quote_idx| {
                    version_str = start[0..quote_idx];
                }
                break;
            }
        }
        
        if (version_str == null) {
            std.debug.print("Could not parse stable version from channel toml.\n", .{});
            return error.VersionNotFound;
        }
        
        target_version = try allocator.dupe(u8, version_str.?);
    }
    defer allocator.free(target_version);
    
    std.debug.print("Target Rust version: {s}\n", .{target_version});

    const arch_str = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "armv7",
        .powerpc64le => "powerpc64le",
        .x86 => "i686",
        else => return error.UnsupportedArch,
    };
    
    const os_target = switch (builtin.os.tag) {
        .linux => "unknown-linux-gnu",
        .macos => "apple-darwin",
        .windows => "pc-windows-msvc",
        else => return error.UnsupportedOS,
    };

    const target_triple = try std.fmt.allocPrint(allocator, "{s}-{s}", .{arch_str, os_target});
    defer allocator.free(target_triple);

    const filename = try std.fmt.allocPrint(allocator, "rust-{s}-{s}.tar.gz", .{target_version, target_triple});
    defer allocator.free(filename);
    
    const tarball_url = try std.fmt.allocPrint(allocator, "https://static.rust-lang.org/dist/{s}", .{filename});
    defer allocator.free(tarball_url);

    // Fetch .sha256
    const shasum_url = try std.fmt.allocPrint(allocator, "https://static.rust-lang.org/dist/{s}.sha256", .{filename});
    defer allocator.free(shasum_url);

    const shasum_uri = try std.Uri.parse(shasum_url);
    var shasum_req = try client.request(.GET, shasum_uri, .{});
    defer shasum_req.deinit();

    try shasum_req.sendBodiless();
    var shasum_server_header_buffer: [8192]u8 = undefined;
    var shasum_res = try shasum_req.receiveHead(&shasum_server_header_buffer);

    var shasum: ?[]const u8 = null;
    if (shasum_res.head.status == .ok) {
        var shasum_transfer_buf: [8192]u8 = undefined;
        var shasum_decompress_buf: [65536]u8 = undefined;
        var shasum_decompress: std.http.Decompress = undefined;
        const limit: std.io.Limit = @enumFromInt(10 * 1024 * 1024);
        const shasum_body = try shasum_res.readerDecompressing(&shasum_transfer_buf, &shasum_decompress, &shasum_decompress_buf).allocRemaining(allocator, limit);
        defer allocator.free(shasum_body);

        if (std.mem.indexOf(u8, shasum_body, " ")) |space_idx| {
            shasum = try allocator.dupe(u8, shasum_body[0..space_idx]);
        }
    }
    
    var bins = try allocator.alloc([]const u8, 3);
    if (builtin.os.tag == .windows) {
        bins[0] = try allocator.dupe(u8, "bin/rustc.exe");
        bins[1] = try allocator.dupe(u8, "bin/cargo.exe");
        bins[2] = try allocator.dupe(u8, "bin/rustfmt.exe");
    } else {
        bins[0] = try allocator.dupe(u8, "bin/rustc");
        bins[1] = try allocator.dupe(u8, "bin/cargo");
        bins[2] = try allocator.dupe(u8, "bin/rustfmt");
    }
    defer {
        allocator.free(bins[0]);
        allocator.free(bins[1]);
        allocator.free(bins[2]);
        allocator.free(bins);
    }
    
    const extract_dir = try std.fmt.allocPrint(allocator, "rust-{s}-{s}", .{target_version, target_triple});
    defer allocator.free(extract_dir);

    const config = registry.InstallModeConfig{
        .type = try allocator.dupe(u8, "archive"),
        .url = try allocator.dupe(u8, tarball_url),
        .checksum = shasum,
        .extract_dir = try allocator.dupe(u8, extract_dir),
        .bin = bins,
    };
    defer {
        allocator.free(config.type);
        allocator.free(config.url.?);
        if (config.checksum) |c| allocator.free(c);
        allocator.free(config.extract_dir.?);
    }
    
    std.debug.print("Downloading Rust from {s}...\n", .{tarball_url});
    
    try core.executeRuntimeInstall(allocator, db_conn, "rust", target_version, config, mode);
}
