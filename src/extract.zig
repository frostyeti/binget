const std = @import("std");
const archive = @import("archive.zig");
const core = @import("core.zig");

const extract_help =
    \\Extract an archive file locally.
    \\
    \\Usage:
    \\  binget extract <archive_path> [files...] [-o <out_dir>] [--ignore-folders]
    \\
    \\Options:
    \\  -o, --out          Destination directory (default: current directory)
    \\  -i, --ignore-folders Extract all files directly into the output directory, ignoring their original paths
    \\  -h, --help         Show this help message and exit
    \\
;

pub fn parseAndRun(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 3 or std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help")) {
        std.debug.print("{s}", .{extract_help});
        return;
    }

    var archive_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var ignore_folders = false;
    var files_to_extract = std.ArrayList([]const u8).empty;
    defer files_to_extract.deinit(allocator);

    var i: usize = 2;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i < args.len) {
                out_dir = args[i];
            } else {
                std.debug.print("Error: -o requires a path\n", .{});
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--ignore-folders") or std.mem.eql(u8, arg, "-i")) {
            ignore_folders = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return error.InvalidArgument;
        } else {
            if (archive_path == null) {
                archive_path = arg;
            } else {
                try files_to_extract.append(allocator, arg);
            }
        }
        i += 1;
    }

    if (archive_path == null) {
        std.debug.print("Error: Archive path is required\n", .{});
        std.debug.print("{s}", .{extract_help});
        return error.InvalidArgument;
    }

    var final_out: []const u8 = undefined;
    if (out_dir) |od| {
        final_out = std.fs.cwd().realpathAlloc(allocator, od) catch try allocator.dupe(u8, od);
    } else {
        final_out = try std.fs.cwd().realpathAlloc(allocator, ".");
    }
    defer allocator.free(final_out);

    std.debug.print("Extracting {s} to {s}...\n", .{ archive_path.?, final_out });

    if (files_to_extract.items.len == 0 and !ignore_folders) {
        // Fast path: Just extract directly
        try archive.extractArchive(allocator, archive_path.?, final_out, archive_path.?, null);
    } else {
        // Extract to tmp, then filter/flatten
        const platform = @import("platform.zig");
        const share_dir = try platform.getBingetShareDir(allocator);
        defer allocator.free(share_dir);

        // Generate random string
        const rand_seed: u64 = @bitCast(std.time.timestamp());
        var prng = std.Random.DefaultPrng.init(rand_seed);
        const random = prng.random();

        var rand_str: [8]u8 = undefined;
        const charset = "abcdefghijklmnopqrstuvwxyz0123456789";
        for (&rand_str) |*c| {
            c.* = charset[random.intRangeLessThan(usize, 0, charset.len)];
        }

        const tmp_name = try std.fmt.allocPrint(allocator, "extract_tmp_{s}", .{rand_str});
        defer allocator.free(tmp_name);

        const tmp_dir_path = try std.fs.path.join(allocator, &.{ share_dir, tmp_name });
        defer allocator.free(tmp_dir_path);

        try std.fs.cwd().makePath(tmp_dir_path);
        defer std.fs.cwd().deleteTree(tmp_dir_path) catch {};

        try archive.extractArchive(allocator, archive_path.?, tmp_dir_path, archive_path.?, null);

        try std.fs.cwd().makePath(final_out);

        // Copy files
        var tmp_dir = try std.fs.cwd().openDir(tmp_dir_path, .{ .iterate = true });
        defer tmp_dir.close();

        var walker = try tmp_dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .directory) continue;

            var should_extract = false;
            if (files_to_extract.items.len == 0) {
                should_extract = true;
            } else {
                for (files_to_extract.items) |wanted| {
                    if (std.mem.indexOf(u8, entry.path, wanted) != null) {
                        should_extract = true;
                        break;
                    }
                }
            }

            if (should_extract) {
                const src_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, entry.path });
                defer allocator.free(src_path);

                var dest_path: []const u8 = undefined;
                if (ignore_folders) {
                    dest_path = try std.fs.path.join(allocator, &.{ final_out, entry.basename });
                } else {
                    dest_path = try std.fs.path.join(allocator, &.{ final_out, entry.path });
                    if (std.fs.path.dirname(dest_path)) |dir_name| {
                        try std.fs.cwd().makePath(dir_name);
                    }
                }
                defer allocator.free(dest_path);

                std.fs.cwd().copyFile(src_path, std.fs.cwd(), dest_path, .{}) catch |err| {
                    std.debug.print("Failed to copy {s} to {s}: {}\n", .{ src_path, dest_path, err });
                };
            }
        }
    }

    std.debug.print("Successfully extracted to {s}\n", .{final_out});
}
