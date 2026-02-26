const std = @import("std");
const env = @import("env.zig");
const platform = @import("platform.zig");

const shell_help =
    \\Manage shell integration.
    \\
    \\Usage:
    \\  binget shell <activate|hook> [<shell>]
    \\
    \\Commands:
    \\  activate         Output shell commands to activate local environment
    \\  hook             Output shell commands to add binget to PATH
    \\  compute          Internal command to evaluate env
    \\
    \\Options:
    \\  -h, --help       Show this help message and exit
    \\
;

pub fn parseAndRun(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 3 or std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help")) {
        std.debug.print("{s}", .{shell_help});
        return;
    }

    const subcmd = args[2];

    if (std.mem.eql(u8, subcmd, "compute")) {
        if (args.len < 4) {
            std.debug.print("Usage: binget shell compute <bash|zsh|fish|pwsh>\n", .{});
            return;
        }
        const shell = args[3];
        env.computeEnvDiff(allocator, shell) catch |err| {
            if (err != error.NotTrusted) return err;
        };
        return;
    }

    if (std.mem.eql(u8, subcmd, "activate")) {
        if (args.len < 4) {
            std.debug.print("Usage: binget shell activate <bash|zsh|fish|pwsh>\n", .{});
            return;
        }
        const shell = args[3];
        env.shellActivate(allocator, shell) catch |err| {
            if (err != error.NotTrusted) return err;
        };
    } else if (std.mem.eql(u8, subcmd, "hook")) {
        // Setup paths in shell profile
        const global = false;
        const bin_dir = try platform.getInstallDir(allocator, global);
        defer allocator.free(bin_dir);

        const shell = try platform.detectShell(allocator);
        const builtin = @import("builtin");
        const fmt_path = try platform.formatPathForShell(allocator, bin_dir, shell, builtin.os.tag);
        defer allocator.free(fmt_path);

        const stdout = std.fs.File.stdout();
        if (std.fmt.allocPrint(allocator, "export PATH=\"{s}:$PATH\"\n", .{fmt_path})) |msg| {
            stdout.writeAll(msg) catch {};
            allocator.free(msg);
        } else |_| {}
    } else {
        std.debug.print("Unknown shell command: {s}\n", .{subcmd});
        std.debug.print("{s}", .{shell_help});
    }
}
