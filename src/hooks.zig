const std = @import("std");
const platform = @import("platform.zig");
const builtin = @import("builtin");
const core = @import("core.zig");
const db = @import("db.zig");
const install_cmd = @import("install_cmd.zig");

const config = @import("config.zig");

pub const HookType = enum {
    pre_install,
    post_install,
    pre_uninstall,
    post_uninstall,
    pre_upgrade,
    post_upgrade,

    pub fn asString(self: HookType) []const u8 {
        return @tagName(self);
    }
};

fn promptUser(message: []const u8) !bool {
    std.debug.print("{s} [y/N]: ", .{message});

    var buf: [16]u8 = undefined;
    const bytes_read = try std.fs.File.stdin().read(&buf);

    if (bytes_read == 0) return false;

    const line = buf[0..bytes_read];
    const trimmed = std.mem.trim(u8, line, " \r\n\t");

    if (std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes")) {
        return true;
    }
    return false;
}

pub fn runHook(allocator: std.mem.Allocator, db_conn: db.Database, hook_type: HookType, pkg_id: []const u8, version: ?[]const u8, skip_prompts: bool) anyerror!void {
    var cfg = try config.loadConfig(allocator);
    defer cfg.deinit(allocator);

    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);

    const usr_dir = try std.fs.path.join(allocator, &.{ share_dir, "usr", pkg_id });
    defer allocator.free(usr_dir);

    var hook_script_path: ?[]const u8 = null;

    if (version) |v| {
        const ver_dir = try std.fs.path.join(allocator, &.{ usr_dir, v });
        defer allocator.free(ver_dir);

        hook_script_path = try findHookScript(allocator, ver_dir, hook_type.asString(), cfg.script_extension_preference);
    }

    if (hook_script_path == null) {
        hook_script_path = try findHookScript(allocator, usr_dir, hook_type.asString(), cfg.script_extension_preference);
    }

    if (hook_script_path) |script_path| {
        defer allocator.free(script_path);

        if (!skip_prompts) {
            const msg = try std.fmt.allocPrint(allocator, "\nPackage '{s}' wants to run a {s} script: {s}\nAllow?", .{ pkg_id, hook_type.asString(), script_path });
            defer allocator.free(msg);

            const allowed = try promptUser(msg);
            if (!allowed) {
                std.debug.print("Skipping {s} script.\n", .{hook_type.asString()});
                return;
            }
        }

        try executeHookScript(allocator, db_conn, script_path);
    }
}

fn ensureRuntimeInstalled(allocator: std.mem.Allocator, db_conn: db.Database, runtime_pkg: []const u8) anyerror!void {
    // Basic check using 'which' or equivalent, or we just try checking db
    // Wait, the easiest way is to check the database
    // Actually, `installRegistryId` skips if already installed? core doesn't currently, it just overwrites.
    // Let's implement a simple check in db_conn.

    var is_installed = false;
    const z_pkg = try allocator.dupeZ(u8, runtime_pkg);
    defer allocator.free(z_pkg);

    if (try db_conn.getInstalledVersion(allocator, z_pkg)) |ver| {
        allocator.free(ver);
        is_installed = true;
    }

    if (!is_installed) {
        std.debug.print("\nRequired runtime '{s}' for script is missing. Auto-installing...\n", .{runtime_pkg});
        try core.installRegistryId(allocator, db_conn, runtime_pkg, null, .user, true); // true to skip prompts for dependencies
    }
}

fn executeHookScript(allocator: std.mem.Allocator, db_conn: db.Database, script_path: []const u8) anyerror!void {
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);

    const ext = std.fs.path.extension(script_path);

    if (std.mem.eql(u8, ext, ".ts")) {
        try ensureRuntimeInstalled(allocator, db_conn, "deno");
        try args.appendSlice(allocator, &.{ "deno", "run", "-A", script_path });
    } else if (std.mem.eql(u8, ext, ".ps1")) {
        try ensureRuntimeInstalled(allocator, db_conn, "pwsh");
        try args.appendSlice(allocator, &.{ "pwsh", "-ExecutionPolicy", "Bypass", "-File", script_path });
    } else if (std.mem.eql(u8, ext, ".sh")) {
        if (builtin.os.tag == .windows) {
            try ensureRuntimeInstalled(allocator, db_conn, "git"); // Git for Windows provides bash
            // Try to find bash from git, or just assume it's in PATH now
            try args.appendSlice(allocator, &.{ "bash", script_path });
        } else {
            try args.appendSlice(allocator, &.{ "bash", script_path }); // or sh
        }
    } else {
        std.debug.print("Unsupported hook script extension: {s}\n", .{ext});
        return;
    }

    std.debug.print("Executing hook: {s}\n", .{script_path});

    var child = std.process.Child.init(args.items, allocator);
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Warning: Hook script exited with code {d}\n", .{code});
            }
        },
        else => {
            std.debug.print("Warning: Hook script terminated abnormally\n", .{});
        },
    }
}

fn findHookScript(allocator: std.mem.Allocator, base_path: []const u8, hook_name: []const u8, exts: [][]const u8) !?[]const u8 {
    for (exts) |ext| {
        const script_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ hook_name, ext });
        defer allocator.free(script_name);

        const full_path = try std.fs.path.join(allocator, &.{ base_path, script_name });

        std.fs.accessAbsolute(full_path, .{}) catch {
            allocator.free(full_path);
            continue;
        };

        return full_path;
    }

    if (std.mem.eql(u8, hook_name, "post_install")) {
        for (exts) |ext| {
            const script_name = try std.fmt.allocPrint(allocator, "install{s}", .{ext});
            defer allocator.free(script_name);
            const full_path = try std.fs.path.join(allocator, &.{ base_path, script_name });
            std.fs.accessAbsolute(full_path, .{}) catch {
                allocator.free(full_path);
                continue;
            };
            return full_path;
        }
    }
    if (std.mem.eql(u8, hook_name, "post_uninstall")) {
        for (exts) |ext| {
            const script_name = try std.fmt.allocPrint(allocator, "uninstall{s}", .{ext});
            defer allocator.free(script_name);
            const full_path = try std.fs.path.join(allocator, &.{ base_path, script_name });
            std.fs.accessAbsolute(full_path, .{}) catch {
                allocator.free(full_path);
                continue;
            };
            return full_path;
        }
    }

    return null;
}
