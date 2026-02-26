const std = @import("std");
const platform = @import("platform.zig");
const archive = @import("archive.zig");

pub fn createShim(allocator: std.mem.Allocator, target_exe: []const u8, bin_dir: []const u8, bin_name: []const u8) !void {
    const builtin = @import("builtin");

    try std.fs.cwd().makePath(bin_dir);

    if (builtin.os.tag == .windows) {
        // Find ScoopInstaller/Shim locally, if missing download it
        const shim_exe_path = try ensureWindowsShimExists(allocator);
        defer allocator.free(shim_exe_path);

        var dest_name = try allocator.dupe(u8, bin_name);
        defer allocator.free(dest_name);

        if (!std.mem.endsWith(u8, dest_name, ".exe")) {
            const temp = dest_name;
            dest_name = try std.fmt.allocPrint(allocator, "{s}.exe", .{dest_name});
            allocator.free(temp);
        }

        const dest_path = try std.fs.path.join(allocator, &.{ bin_dir, dest_name });
        defer allocator.free(dest_path);

        const shim_cfg_name = try std.fmt.allocPrint(allocator, "{s}.shim", .{dest_name[0 .. dest_name.len - 4]});
        defer allocator.free(shim_cfg_name);

        const dest_shim_cfg = try std.fs.path.join(allocator, &.{ bin_dir, shim_cfg_name });
        defer allocator.free(dest_shim_cfg);

        std.fs.cwd().deleteFile(dest_path) catch {};
        std.fs.cwd().deleteFile(dest_shim_cfg) catch {};

        try std.fs.cwd().copyFile(shim_exe_path, std.fs.cwd(), dest_path, .{});

        var cfg_file = try std.fs.cwd().createFile(dest_shim_cfg, .{});
        defer cfg_file.close();

        const cfg_content = try std.fmt.allocPrint(allocator, "path = {s}\n", .{target_exe});
        defer allocator.free(cfg_content);
        try cfg_file.writeAll(cfg_content);

        std.debug.print("Created Windows shim at {s}\n", .{dest_path});
    } else {
        const dest_path = try std.fs.path.join(allocator, &.{ bin_dir, bin_name });
        defer allocator.free(dest_path);

        std.fs.cwd().deleteFile(dest_path) catch {};

        std.fs.cwd().symLink(target_exe, dest_path, .{}) catch |err| {
            std.debug.print("Failed to create symlink for shim: {}\n", .{err});
            return err;
        };
        std.debug.print("Created symlink shim at {s}\n", .{dest_path});
    }
}

fn ensureWindowsShimExists(allocator: std.mem.Allocator) ![]const u8 {
    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);

    const tools_dir = try std.fs.path.join(allocator, &.{ share_dir, "tools" });
    defer allocator.free(tools_dir);

    try std.fs.cwd().makePath(tools_dir);

    const shim_path = try std.fs.path.join(allocator, &.{ tools_dir, "shim.exe" });

    if (std.fs.cwd().access(shim_path, .{})) {
        // already exists
        return shim_path;
    } else |_| {
        // does not exist, download it
        const url = "https://github.com/ScoopInstaller/Shim/releases/download/v1.1.0/shim-1.1.0.zip";
        const tmp_zip = try std.fs.path.join(allocator, &.{ tools_dir, "shim.zip" });
        defer allocator.free(tmp_zip);

        std.debug.print("Downloading Windows Shim engine...\n", .{});
        try archive.downloadFile(allocator, url, tmp_zip);

        // extract it
        const tmp_extract = try std.fs.path.join(allocator, &.{ tools_dir, "shim_tmp" });
        defer allocator.free(tmp_extract);
        std.fs.cwd().deleteTree(tmp_extract) catch {};

        try archive.extractArchive(allocator, tmp_zip, tmp_extract, url, null);

        const extracted_shim = try std.fs.path.join(allocator, &.{ tmp_extract, "shim.exe" });
        defer allocator.free(extracted_shim);

        try std.fs.cwd().copyFile(extracted_shim, std.fs.cwd(), shim_path, .{});

        std.fs.cwd().deleteFile(tmp_zip) catch {};
        std.fs.cwd().deleteTree(tmp_extract) catch {};
    }

    return shim_path;
}
