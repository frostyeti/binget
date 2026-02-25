const std = @import("std");
pub const platform = @import("platform.zig");
pub const db = @import("db.zig");
pub const github = @import("github.zig");
pub const archive = @import("archive.zig");
pub const core = @import("core.zig");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "install")) {
            if (args.len < 3) {
                std.debug.print("Usage: binget install <owner/repo> [--global]\n", .{});
                return;
            }
            const target = args[2];
            var global = false;
            if (args.len > 3 and std.mem.eql(u8, args[3], "--global")) {
                global = true;
            }

            const share_dir = try platform.getBingetShareDir(allocator);
            defer allocator.free(share_dir);
            try std.fs.cwd().makePath(share_dir);

            const db_path = try std.fs.path.join(allocator, &.{ share_dir, "binget.db" });
            defer allocator.free(db_path);
            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            var db_conn = try db.Database.open(db_path_z);
            defer db_conn.close();

            try core.installPackage(allocator, db_conn, target, global);
        } else if (std.mem.eql(u8, args[1], "env")) {
            if (args.len < 3) {
                std.debug.print("Usage: binget env <bash|zsh|fish|pwsh>\n", .{});
                return;
            }
            const shell = args[2];
            const env = @import("env.zig");
            try env.printEnv(allocator, shell);
        } else if (std.mem.eql(u8, args[1], "shell-hook")) {
            // Setup paths in shell profile
            const global = false;
            const bin_dir = try platform.getInstallDir(allocator, global);
            defer allocator.free(bin_dir);

            const shell = try platform.detectShell(allocator);
            const builtin = @import("builtin");
            const fmt_path = try platform.formatPathForShell(allocator, bin_dir, shell, builtin.os.tag);
            defer allocator.free(fmt_path);
            
            std.debug.print("export PATH=\"{s}:$PATH\"\n", .{fmt_path});
        } else {
            std.debug.print("Command: {s}\n", .{args[1]});
        }
    } else {
        std.debug.print("Usage: binget [install|shell-hook] <args>\n", .{});
    }
}
