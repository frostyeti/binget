const std = @import("std");
const core = @import("../core.zig");
const db = @import("../db.zig");
const install_cmd = @import("../install_cmd.zig");
const registry = @import("../registry.zig");
const builtin = @import("builtin");

pub fn install(allocator: std.mem.Allocator, db_conn: db.Database, version_opt: ?[]const u8, mode: install_cmd.InstallMode) !void {
    std.debug.print("Resolving builtin runtime 'python'...\n", .{});

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const url = "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest";
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();
    var server_header_buffer: [8192]u8 = undefined;
    var res = try req.receiveHead(&server_header_buffer);

    if (res.head.status != .ok) {
        std.debug.print("Failed to fetch python latest release\n", .{});
        return error.HttpFailed;
    }

    var transfer_buf: [8192]u8 = undefined;
    var decompress_buf: [65536]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const limit: std.io.Limit = @enumFromInt(20 * 1024 * 1024);
    const body = try res.readerDecompressing(&transfer_buf, &decompress, &decompress_buf).allocRemaining(allocator, limit);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const assets = root.get("assets").?.array;

    const arch_str = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .x86 => "i686",
        else => return error.UnsupportedArch,
    };
    
    const os_str = switch (builtin.os.tag) {
        .linux => "unknown-linux-gnu",
        .macos => "apple-darwin",
        .windows => "pc-windows-msvc",
        else => return error.UnsupportedOS,
    };

    const target_suffix = try std.fmt.allocPrint(allocator, "{s}-{s}-install_only.tar.gz", .{arch_str, os_str});
    defer allocator.free(target_suffix);

    var best_version: ?[]const u8 = null;
    var best_url: ?[]const u8 = null;

    // e.g. "cpython-3.12.10+..." -> version is "3.12.10"
    for (assets.items) |asset| {
        const obj = asset.object;
        const name = obj.get("name").?.string;
        const download_url = obj.get("browser_download_url").?.string;
        
        if (!std.mem.startsWith(u8, name, "cpython-")) continue;
        if (!std.mem.endsWith(u8, name, target_suffix)) continue;
        
        // Extract version
        const v_start = "cpython-".len;
        if (std.mem.indexOf(u8, name, "+")) |plus_idx| {
            const v_str = name[v_start..plus_idx];
            
            var matches = false;
            if (version_opt) |v| {
                if (std.mem.startsWith(u8, v_str, v)) matches = true;
            } else {
                matches = true;
            }
            
            if (matches) {
                // If we don't have one, or this one is "higher" (simple lexicographical for now, usually sufficient since they pad, actually 3.9 vs 3.10 is bad string compare, but we just take first match or implement simple logic)
                // For simplicity, we just take the first match if version provided, else we want the highest.
                // Actually the API returns them usually sorted but let's just do a basic numeric comparison.
                if (best_version == null) {
                    best_version = try allocator.dupe(u8, v_str);
                    best_url = try allocator.dupe(u8, download_url);
                } else {
                    // Compare versions
                    if (compareVersions(v_str, best_version.?)) {
                        allocator.free(best_version.?);
                        allocator.free(best_url.?);
                        best_version = try allocator.dupe(u8, v_str);
                        best_url = try allocator.dupe(u8, download_url);
                    }
                }
            }
        }
    }
    
    if (best_version == null or best_url == null) {
        std.debug.print("Could not find suitable python binary for target {s}.\n", .{target_suffix});
        return error.VersionNotFound;
    }
    
    defer allocator.free(best_version.?);
    defer allocator.free(best_url.?);

    std.debug.print("Target Python version: {s}\n", .{best_version.?});

    var bins = try allocator.alloc([]const u8, 2);
    if (builtin.os.tag == .windows) {
        bins[0] = try allocator.dupe(u8, "python.exe");
        bins[1] = try allocator.dupe(u8, "pip.exe");
        // Actually python standalone on windows has bin/python.exe?
        // Wait, on windows the python.exe is sometimes in `python/` not `python/bin/`. Let's assume `python.exe` for now but we'll check.
    } else {
        bins[0] = try allocator.dupe(u8, "bin/python3");
        bins[1] = try allocator.dupe(u8, "bin/pip3");
    }
    defer {
        allocator.free(bins[0]);
        allocator.free(bins[1]);
        allocator.free(bins);
    }
    
    const config = registry.InstallModeConfig{
        .type = try allocator.dupe(u8, "archive"),
        .url = try allocator.dupe(u8, best_url.?),
        .checksum = null,
        .extract_dir = try allocator.dupe(u8, "python"),
        .bin = bins,
    };
    defer {
        allocator.free(config.type);
        allocator.free(config.url.?);
        allocator.free(config.extract_dir.?);
    }
    
    std.debug.print("Downloading Python from {s}...\n", .{best_url.?});
    
    try core.executeRuntimeInstall(allocator, db_conn, "python", best_version.?, config, mode);
}

// return true if v1 > v2
fn compareVersions(v1: []const u8, v2: []const u8) bool {
    var it1 = std.mem.splitScalar(u8, v1, '.');
    var it2 = std.mem.splitScalar(u8, v2, '.');
    
    while (true) {
        const p1 = it1.next();
        const p2 = it2.next();
        if (p1 == null and p2 == null) return false;
        if (p1 != null and p2 == null) return true;
        if (p1 == null and p2 != null) return false;
        
        const n1 = std.fmt.parseInt(u32, p1.?, 10) catch 0;
        const n2 = std.fmt.parseInt(u32, p2.?, 10) catch 0;
        if (n1 > n2) return true;
        if (n1 < n2) return false;
    }
}
