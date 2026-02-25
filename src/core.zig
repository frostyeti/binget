const std = @import("std");
const platform = @import("platform.zig");
const github = @import("github.zig");
const archive = @import("archive.zig");
const db = @import("db.zig");

pub fn getAssetArchAndOs() struct { arch: []const u8, os: []const u8 } {
    const builtin = @import("builtin");
    const os_tag = @tagName(builtin.os.tag);
    const arch_tag = @tagName(builtin.cpu.arch);
    return .{ .arch = arch_tag, .os = os_tag };
}

pub fn guessAsset(assets: []github.Release.Asset) ?[]const u8 {
    const sys = getAssetArchAndOs();
    
    var best_score: i32 = -1;
    var best_url: ?[]const u8 = null;

    for (assets) |asset| {
        var score: i32 = 0;
        const name = asset.name;

        if (std.ascii.indexOfIgnoreCase(name, sys.os) != null) score += 10;
        if (std.ascii.indexOfIgnoreCase(name, sys.arch) != null) score += 10;

        if (std.mem.eql(u8, sys.arch, "x86_64") and std.ascii.indexOfIgnoreCase(name, "amd64") != null) score += 10;
        if (std.mem.eql(u8, sys.os, "macos") and std.ascii.indexOfIgnoreCase(name, "darwin") != null) score += 10;
        if (std.mem.eql(u8, sys.os, "windows") and std.ascii.indexOfIgnoreCase(name, "win") != null) score += 10;

        if (std.ascii.endsWithIgnoreCase(name, ".tar.gz") or std.ascii.endsWithIgnoreCase(name, ".tgz")) score += 5;
        if (std.ascii.endsWithIgnoreCase(name, ".tar.xz") or std.ascii.endsWithIgnoreCase(name, ".txz")) score += 5;
        if (std.ascii.endsWithIgnoreCase(name, ".tar.bz2") or std.ascii.endsWithIgnoreCase(name, ".tbz2") or std.ascii.endsWithIgnoreCase(name, ".tar.bz")) score += 5;
        if (std.ascii.endsWithIgnoreCase(name, ".zip")) score += 5;

        if (score > best_score and score >= 20) {
            best_score = score;
            best_url = asset.browser_download_url;
        }
    }
    return best_url;
}

pub fn installPackage(allocator: std.mem.Allocator, db_conn: db.Database, target: []const u8, global: bool) !void {
    var split = std.mem.splitScalar(u8, target, '/');
    const owner = split.next() orelse return error.InvalidTarget;
    const repo = split.next() orelse return error.InvalidTarget;

    std.debug.print("Fetching release info for {s}/{s}...\n", .{owner, repo});
    const release = try github.fetchLatestRelease(allocator, owner, repo);
    defer github.freeRelease(allocator, release);

    std.debug.print("Found latest release: {s}\n", .{release.tag_name});

    const url = guessAsset(release.assets) orelse {
        std.debug.print("Could not find a suitable asset for this OS/Arch.\n", .{});
        return error.NoAssetFound;
    };

    std.debug.print("Downloading: {s}\n", .{url});
    
    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);

    const tmp_dir_path = try std.fs.path.join(allocator, &.{ share_dir, ".tmp" });
    defer allocator.free(tmp_dir_path);

    try std.fs.cwd().makePath(tmp_dir_path);
    // Cleanup any old temp files silently
    std.fs.cwd().deleteTree(tmp_dir_path) catch {};
    try std.fs.cwd().makePath(tmp_dir_path);
    defer std.fs.cwd().deleteTree(tmp_dir_path) catch {};

    const archive_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, "downloaded_archive" });
    defer allocator.free(archive_path);

    try archive.downloadFile(allocator, url, archive_path);

    const extract_dir = try std.fs.path.join(allocator, &.{ tmp_dir_path, "extracted" });
    defer allocator.free(extract_dir);
    try archive.extractArchive(allocator, archive_path, extract_dir);

    const pkg_dir = try std.fs.path.join(allocator, &.{ share_dir, "packages", repo, release.tag_name });
    defer allocator.free(pkg_dir);
    try std.fs.cwd().makePath(pkg_dir);

    // Find binary
    const builtin = @import("builtin");
    const exe_name = if (builtin.os.tag == .windows) try std.fmt.allocPrint(allocator, "{s}.exe", .{repo}) else try allocator.dupe(u8, repo);
    defer allocator.free(exe_name);

    var found_exe: ?[]const u8 = null;
    
    var dir = try std.fs.cwd().openDir(extract_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var largest_file: ?[]const u8 = null;
    var largest_size: u64 = 0;

    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            // Check if exact match
            if (std.mem.eql(u8, entry.basename, repo) or std.mem.eql(u8, entry.basename, exe_name)) {
                found_exe = try std.fs.path.join(allocator, &.{ extract_dir, entry.path });
                break;
            }
            // Heuristic for executable: no extension on unix, .exe on windows
            const ext = std.fs.path.extension(entry.basename);
            var is_possible_bin = false;
            if (builtin.os.tag == .windows) {
                if (std.ascii.eqlIgnoreCase(ext, ".exe")) is_possible_bin = true;
            } else {
                if (ext.len == 0) is_possible_bin = true;
            }
            
            if (is_possible_bin) {
                const stat = try dir.statFile(entry.path);
                if (stat.size > largest_size) {
                    largest_size = stat.size;
                    if (largest_file) |lf| allocator.free(lf);
                    largest_file = try std.fs.path.join(allocator, &.{ extract_dir, entry.path });
                }
            }
        }
    }

    if (found_exe == null and largest_file != null) {
        found_exe = largest_file;
    } else if (largest_file != null) {
        allocator.free(largest_file.?);
    }

    if (found_exe) |exe_path| {
        defer allocator.free(exe_path);
        const final_exe_path = try std.fs.path.join(allocator, &.{ pkg_dir, exe_name });
        defer allocator.free(final_exe_path);

        try std.fs.cwd().rename(exe_path, final_exe_path);
        try archive.makeExecutable(final_exe_path);

        const bin_dir = try platform.getInstallDir(allocator, global);
        defer allocator.free(bin_dir);
        try std.fs.cwd().makePath(bin_dir);

        const link_path = try std.fs.path.join(allocator, &.{ bin_dir, exe_name });
        defer allocator.free(link_path);

        std.fs.cwd().deleteFile(link_path) catch {};
        
        try std.fs.cwd().symLink(final_exe_path, link_path, .{});
        
        std.debug.print("Successfully installed {s} to {s}\n", .{ repo, link_path });

        const name_z = try allocator.dupeZ(u8, target);
        defer allocator.free(name_z);
        const version_z = try allocator.dupeZ(u8, release.tag_name);
        defer allocator.free(version_z);
        const link_path_z = try allocator.dupeZ(u8, link_path);
        defer allocator.free(link_path_z);

        try db_conn.recordInstall(name_z, version_z, link_path_z, global);
    } else {
        std.debug.print("Could not find binary named '{s}' inside the archive.\n", .{repo});
    }
}
