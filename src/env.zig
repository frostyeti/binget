const std = @import("std");
const platform = @import("platform.zig");

pub fn findConfig(allocator: std.mem.Allocator) !?[]const u8 {
    var curr_dir = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(curr_dir);

    while (true) {
        const yaml_path = try std.fs.path.join(allocator, &.{ curr_dir, ".binget.yaml" });
        defer allocator.free(yaml_path);

        if (std.fs.cwd().access(yaml_path, .{})) |_| {
            return try allocator.dupe(u8, yaml_path);
        } else |_| {}

        const parent = std.fs.path.dirname(curr_dir);
        if (parent == null or std.mem.eql(u8, parent.?, curr_dir)) {
            break;
        }
        
        // reallocate curr_dir
        const next_dir = try allocator.dupe(u8, parent.?);
        allocator.free(curr_dir);
        curr_dir = next_dir;
    }
    return null;
}

pub fn printEnv(allocator: std.mem.Allocator, shell_name: []const u8) !void {
    const config_path = try findConfig(allocator);
    if (config_path == null) {
        // No config found, clear bindings if needed (too complex for MVP, just exit)
        return;
    }
    defer allocator.free(config_path.?);

    // Read config
    var file = try std.fs.cwd().openFile(config_path.?, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Extremely basic parsing: looking for lines like "pkg: version"
    var iter = std.mem.splitScalar(u8, content, '\n');
    var paths = std.ArrayList([]const u8).init(allocator);
    defer paths.deinit();

    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);

    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var parts = std.mem.splitScalar(u8, trimmed, ':');
        const pkg_raw = parts.next() orelse continue;
        const ver_raw = parts.next() orelse continue;
        
        const pkg = std.mem.trim(u8, pkg_raw, " \"'");
        const ver = std.mem.trim(u8, ver_raw, " \"'");

        // Only package name for the folder (part after /)
        var pkg_iter = std.mem.splitScalar(u8, pkg, '/');
        _ = pkg_iter.next();
        const repo = pkg_iter.next() orelse pkg; 

        const pkg_dir = try std.fs.path.join(allocator, &.{ share_dir, "packages", repo, ver });
        try paths.append(pkg_dir);
    }

    if (paths.items.len == 0) return;

    // Join paths
    var paths_str = std.ArrayList(u8).init(allocator);
    defer paths_str.deinit();
    
    const builtin = @import("builtin");

    for (paths.items, 0..) |p, i| {
        // Detect shell and format path
        var shell_type: platform.ShellType = .unknown;
        if (std.mem.eql(u8, shell_name, "bash")) shell_type = .bash;
        if (std.mem.eql(u8, shell_name, "zsh")) shell_type = .zsh;
        if (std.mem.eql(u8, shell_name, "fish")) shell_type = .fish;
        if (std.mem.eql(u8, shell_name, "pwsh")) shell_type = .pwsh;
        if (std.mem.eql(u8, shell_name, "powershell")) shell_type = .powershell;
        
        const fmt_path = platform.formatPathForShell(allocator, p, shell_type, builtin.os.tag) catch try allocator.dupe(u8, p);
        try paths_str.appendSlice(fmt_path);
        allocator.free(fmt_path);

        if (i < paths.items.len - 1) {
            try paths_str.append(':'); // Use OS path separator? In shell env, usually : on linux, ; on windows. But for bash/zsh we use :
        }
        allocator.free(p);
    }

    if (std.mem.eql(u8, shell_name, "bash") or std.mem.eql(u8, shell_name, "zsh")) {
        std.debug.print("export PATH=\"{s}:$PATH\"\n", .{paths_str.items});
    } else if (std.mem.eql(u8, shell_name, "fish")) {
        std.debug.print("set -gx PATH {s} $PATH\n", .{paths_str.items});
    } else if (std.mem.eql(u8, shell_name, "powershell") or std.mem.eql(u8, shell_name, "pwsh")) {
        std.debug.print("$env:PATH = \"{s};\" + $env:PATH\n", .{paths_str.items});
    }
}
