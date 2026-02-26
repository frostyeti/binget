const std = @import("std");
const platform = @import("platform.zig");
const db = @import("db.zig");
const env = @import("env.zig");
const install_cmd = @import("install_cmd.zig");

const add_help =
    \\Add and install a package locally (with .binget).
    \\
    \\Usage:
    \\  binget add <owner/repo>[@version] [--init]
    \\  binget add <id>[@version] [--init]
    \\  binget add -h | --help
    \\
    \\Options:
    \\  --init           Create a .binget file if not present and add hook to .bashrc
    \\  -h, --help       Show this help message and exit
    \\
;

fn setupInit(allocator: std.mem.Allocator) !void {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const conf_path = try std.fs.path.join(allocator, &.{ cwd, ".binget" });
    defer allocator.free(conf_path);

    if (std.fs.cwd().access(conf_path, .{})) |_| {
        std.debug.print(".binget already exists.\n", .{});
    } else |_| {
        var file = try std.fs.cwd().createFile(conf_path, .{});
        defer file.close();
        try file.writeAll("bin:\n");
        std.debug.print("Created .binget in {s}\n", .{cwd});
    }

    // Add to bashrc
    const home_dir = try platform.getHomeDir(allocator);
    defer allocator.free(home_dir);
    const bashrc_path = try std.fs.path.join(allocator, &.{ home_dir, ".bashrc" });
    defer allocator.free(bashrc_path);

    var file = std.fs.cwd().openFile(bashrc_path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try std.fs.cwd().createFile(bashrc_path, .{}),
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    const content = try file.readToEndAlloc(allocator, @intCast(stat.size));
    defer allocator.free(content);

    const hook_cmd = "eval \"$(binget shell activate bash)\"";
    if (std.mem.indexOf(u8, content, hook_cmd) == null) {
        try file.seekFromEnd(0);
        const append_str = try std.fmt.allocPrint(allocator, "\n# binget\n{s}\n", .{hook_cmd});
        defer allocator.free(append_str);
        try file.writeAll(append_str);
        std.debug.print("Added bash hook to {s}\n", .{bashrc_path});
    } else {
        std.debug.print("Bash hook already present in {s}\n", .{bashrc_path});
    }
}

pub fn parseAndRun(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    var target: ?[]const u8 = null;
    var init_flag = false;

    var i: usize = 2;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--init")) {
            init_flag = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{add_help});
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return error.InvalidArgument;
        } else {
            target = arg;
        }
        i += 1;
    }

    const t = target orelse {
        std.debug.print("Error: Target package required.\n\n{s}", .{add_help});
        return error.InvalidArgument;
    };

    if (init_flag) {
        try setupInit(allocator);
    }

    const config_path = try env.findConfig(allocator) orelse {
        std.debug.print("Error: No .binget found. Use --init to create one.\n", .{});
        return error.NoConfigFound;
    };
    defer allocator.free(config_path);

    // Read config
    var conf_file = try std.fs.cwd().openFile(config_path, .{ .mode = .read_write });
    defer conf_file.close();

    const stat = try conf_file.stat();
    const content = try conf_file.readToEndAlloc(allocator, @intCast(stat.size));
    defer allocator.free(content);

    var found = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var has_bin_block = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (std.mem.eql(u8, trimmed, "bin:")) {
            has_bin_block = true;
        }
        if (std.mem.startsWith(u8, trimmed, t)) {
            found = true;
        }
    }

    if (!found) {
        if (!has_bin_block) {
            try conf_file.seekFromEnd(0);
            const append_str = try std.fmt.allocPrint(allocator, "\nbin:\n  {s}\n", .{t});
            defer allocator.free(append_str);
            try conf_file.writeAll(append_str);
        } else {
            try conf_file.seekFromEnd(0);
            const append_str2 = try std.fmt.allocPrint(allocator, "  {s}\n", .{t});
            defer allocator.free(append_str2);
            try conf_file.writeAll(append_str2);
        }
        std.debug.print("Added {s} to {s}\n", .{ t, config_path });
    } else {
        std.debug.print("{s} already in {s}\n", .{ t, config_path });
    }

    // Now install it
    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);
    try std.fs.cwd().makePath(share_dir);

    const db_path = try std.fs.path.join(allocator, &.{ share_dir, "binget.db" });
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);

    var db_conn = try db.Database.open(db_path_z);
    defer db_conn.close();

    try install_cmd.installTarget(allocator, db_conn, t, .shim, false);
}
