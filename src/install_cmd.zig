const std = @import("std");
const core = @import("core.zig");
const db = @import("db.zig");
const binget_file = @import("binget_file.zig");
const platform = @import("platform.zig");
const windows_utils = @import("windows_utils.zig");

pub const InstallMode = enum {
    global,
    user,
    shim,
};

pub fn parseAndRun(allocator: std.mem.Allocator, db_conn: db.Database, args: [][:0]u8) !void {
    var config_path: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var mode: InstallMode = .user;
    var skip_prompts: bool = false;

    var i: usize = 2; // args[0] is binget, args[1] is install
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--global")) {
            mode = .global;
        } else if (std.mem.eql(u8, arg, "--user")) {
            mode = .user;
        } else if (std.mem.eql(u8, arg, "--shim")) {
            mode = .shim;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            skip_prompts = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i < args.len) {
                config_path = args[i];
            } else {
                std.debug.print("Error: --config requires a path\n", .{});
                return error.InvalidArgument;
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                printHelp();
                return;
            }
            std.debug.print("Unknown option: {s}\n", .{arg});
            return error.InvalidArgument;
        } else {
            target = arg;
        }
        i += 1;
    }

    if (target) |t| {
        try installTarget(allocator, db_conn, t, mode, skip_prompts);
    } else {
        try installFromConfig(allocator, db_conn, config_path, skip_prompts);
    }
}

fn printHelp() void {
    const install_help =
        \\Install a package from a repository or a local configuration.
        \\
        \\Usage:
        \\  binget install                             (Installs binaries defined in local .binget)
        \\  binget install --config <path>             (Installs binaries from specified config file)
        \\  binget install <id>[@version]              (Installs package from default registry)
        \\  binget install github.com/<owner>/<repo>[@version] (Installs package from GitHub)
        \\  binget install -h | --help
        \\
        \\Options:
        \\  --global         Install globally
        \\  --user           Install for current user (default)
        \\  --shim           Install to env/<package>/<version> shim directory
        \\  --config <path>  Specify a .binget configuration file
        \\  -h, --help       Show this help message and exit
        \\
    ;
    std.debug.print("{s}", .{install_help});
}

pub fn installTarget(allocator: std.mem.Allocator, db_conn: db.Database, target: []const u8, mode: InstallMode, skip_prompts: bool) !void {
    const is_github_prefix = std.mem.startsWith(u8, target, "github.com/");
    const is_gh_prefix = std.mem.startsWith(u8, target, "gh:");
    var parts = std.mem.splitScalar(u8, target, '@');
    const name_part = parts.next().?;
    const version_opt = parts.next();

    // Check if name_part has a slash, meaning it's an owner/repo format
    const has_slash = std.mem.indexOfScalar(u8, name_part, '/') != null;

    if (is_github_prefix or is_gh_prefix or has_slash) {
        var repo_path = name_part;
        if (is_github_prefix) {
            repo_path = name_part["github.com/".len..];
        } else if (is_gh_prefix) {
            repo_path = name_part["gh:".len..];
        }
        var repo_parts = std.mem.splitScalar(u8, repo_path, '/');
        const owner = repo_parts.next() orelse return error.InvalidTarget;
        const repo = repo_parts.next() orelse return error.InvalidTarget;

        try core.installGithub(allocator, db_conn, owner, repo, version_opt, mode);
    } else {
        const id = name_part;
        const builtin_runtimes = @import("runtimes/builtin.zig");
        if (builtin_runtimes.isBuiltin(id)) {
            try builtin_runtimes.install(allocator, db_conn, id, version_opt, mode);
        } else {
            try core.installRegistryId(allocator, db_conn, id, version_opt, mode, skip_prompts);
        }
    }

    if (@import("builtin").os.tag == .windows) {
        if (mode == .user or mode == .shim) {
            const bin_dir = try platform.getInstallDir(allocator, false);
            defer allocator.free(bin_dir);
            try windows_utils.ensureInUserPath(allocator, bin_dir);
        }
    }
}

pub fn installFromConfig(allocator: std.mem.Allocator, db_conn: db.Database, config_path_opt: ?[]const u8, skip_prompts: bool) !void {
    var path_to_use = config_path_opt;

    var need_free = false;
    if (path_to_use == null) {
        const env = @import("env.zig");
        path_to_use = try env.findConfig(allocator);
        need_free = true;
    }

    defer {
        if (need_free) {
            if (path_to_use) |p| {
                allocator.free(p);
            }
        }
    }

    if (path_to_use) |p| {
        std.debug.print("Installing from config: {s}\n", .{p});
        // We need to parse the file and find the 'bin:' block.
        // For now, we will just read the file, and do naive parsing.

        var file = try std.fs.cwd().openFile(p, .{});
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
        defer allocator.free(content);

        const bf = try binget_file.parseBingetFile(allocator, content);
        // We will need to parse bf.bin_content
        if (bf.bin_content.len > 0) {
            try parseAndInstallBinBlock(allocator, db_conn, bf.bin_content, skip_prompts);
        } else {
            std.debug.print("No 'bin:' block found in config.\n", .{});
        }
    } else {
        std.debug.print("No config file found or specified.\n", .{});
        return error.NoConfigFound;
    }
}

fn parseAndInstallBinBlock(allocator: std.mem.Allocator, db_conn: db.Database, bin_content: []const u8, skip_prompts: bool) !void {
    var lines = std.mem.splitScalar(u8, bin_content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Find top-level items under bin:
        // We accept both indented and unindented items,
        // e.g. "github.com/org/repo: version" or "id@version"

        // Split by ':' or space to get the ID part
        var id_part = trimmed;
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_idx| {
            id_part = std.mem.trimRight(u8, trimmed[0..colon_idx], " \t");
            const val_part = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \t\"'");

            // if val_part is a simple version string, construct id@version
            if (val_part.len > 0 and std.mem.indexOfScalar(u8, val_part, '{') == null) {
                var target_buf = std.ArrayList(u8).empty;
                defer target_buf.deinit(allocator);
                try target_buf.appendSlice(allocator, id_part);
                try target_buf.append(allocator, '@');
                try target_buf.appendSlice(allocator, val_part);

                std.debug.print("Found dependency: {s}\n", .{target_buf.items});
                installTarget(allocator, db_conn, target_buf.items, .shim, skip_prompts) catch |err| {
                    std.debug.print("Failed to install {s}: {}\n", .{ target_buf.items, err });
                };
                continue;
            }
        }

        if (id_part.len > 0 and std.mem.indexOfScalar(u8, id_part, ' ') == null) {
            // heuristic: if it looks like a package id
            if (std.mem.indexOfScalar(u8, id_part, '/') != null or std.mem.indexOfScalar(u8, id_part, '@') != null) {
                std.debug.print("Found dependency: {s}\n", .{id_part});
                installTarget(allocator, db_conn, id_part, .shim, skip_prompts) catch |err| {
                    std.debug.print("Failed to install {s}: {}\n", .{ id_part, err });
                };
            }
        }
    }
}
