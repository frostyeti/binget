const std = @import("std");
const platform = @import("platform.zig");
const archive = @import("archive.zig");

const sources_help =
    \\Manage package repositories.
    \\
    \\Usage:
    \\  binget sources update [--force]
    \\  binget sources -h | --help
    \\
    \\Options:
    \\  --force          Force update even if cache is fresh
    \\  -h, --help       Show this help message and exit
    \\
;

fn getRegistryUrl(allocator: std.mem.Allocator) ![]const u8 {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    if (env_map.get("BINGET_REGISTRY")) |url| {
        return try allocator.dupe(u8, url);
    }
    return try allocator.dupe(u8, "https://raw.githubusercontent.com/frostyeti/binget-pkgs/master");
}

pub fn parseAndRun(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 3 or std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help")) {
        std.debug.print("{s}", .{sources_help});
        return;
    }

    if (std.mem.eql(u8, args[2], "update")) {
        var force = false;
        if (args.len > 3 and std.mem.eql(u8, args[3], "--force")) {
            force = true;
        }

        const share_dir = try platform.getBingetShareDir(allocator);
        defer allocator.free(share_dir);
        try std.fs.cwd().makePath(share_dir);

        const manifest_path = try std.fs.path.join(allocator, &.{ share_dir, "manifest.db" });
        defer allocator.free(manifest_path);

        var needs_update = force;
        if (!needs_update) {
            if (std.fs.cwd().statFile(manifest_path)) |stat| {
                const now = std.time.nanoTimestamp();
                const age_ns = now - stat.mtime;
                const age_hours = @divTrunc(age_ns, 1000 * 1000 * 1000 * 60 * 60);
                if (age_hours >= 24) {
                    needs_update = true;
                }
            } else |_| {
                needs_update = true;
            }
        }

        if (needs_update) {
            std.debug.print("Updating sources...\n", .{});
            const base_url = try getRegistryUrl(allocator);
            defer allocator.free(base_url);

            const url = try std.fmt.allocPrint(allocator, "{s}/manifest.db", .{base_url});
            defer allocator.free(url);

            archive.downloadFile(allocator, url, manifest_path) catch |err| {
                std.debug.print("Failed to download manifest.db: {}\n", .{err});
                return;
            };

            std.debug.print("Successfully updated manifest.db\n", .{});
        } else {
            std.debug.print("Sources are up to date (less than 24 hours old). Use --force to update now.\n", .{});
        }
    } else {
        std.debug.print("Unknown command: {s}\n", .{args[2]});
        std.debug.print("{s}", .{sources_help});
    }
}
