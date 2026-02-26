const std = @import("std");
pub const platform = @import("platform.zig");
pub const db = @import("db.zig");
pub const github = @import("github.zig");
pub const archive = @import("archive.zig");
pub const core = @import("core.zig");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

const uninstall = @import("uninstall.zig");
const upgrade = @import("upgrade.zig");

const global_help =
    \\binget - A binary package manager
    \\
    \\Usage:
    \\  binget <command> [<args>...]
    \\  binget -h | --help
    \\  binget --version
    \\
    \\Commands:
    \\  add              Add and install a package locally (with .binget)
    \\  remove           Remove a package from the local .binget
    \\  install          Install a package globally
    \\  uninstall        Uninstall a globally installed package
    \\  upgrade          Upgrade an installed package
    \\  search           Search the remote registry for a package
    \\  list             List installed packages
    \\  which            Locate the physical installation of a package
    \\  sources          Manage package repositories
    \\  shell            Manage shell integration (activate, hook)
    \\  exec             Execute a command in the binget environment
    \\  new              Initialize a new package
    \\  pack             Pack a package into an archive
    \\  trust            Trust the current directory's binget.yaml
    \\  scan             Scan a package against VirusTotal
    \\  env              Print the environment variables
    \\  version          Print the version
    \\
    \\Options:
    \\  -h, --help       Show this help message and exit
    \\  -v, --version    Show version and exit
    \\
;

// Command help text placeholders
const add_help = "Add and install a package locally.\nUsage: binget add <owner/repo> [--init]\n";
const remove_help = "Remove a package from the local .binget.\nUsage: binget remove <name>\n";
const install_help = "Install a package from a repository.\nUsage: binget install <owner/repo> [--global]\n";
const uninstall_help = "Uninstall a package.\nUsage: binget uninstall <name> [--yes]\n";
const upgrade_help = "Upgrade an installed package.\nUsage: binget upgrade <name> [--global]\n";
const search_help = "Search the remote registry for a package.\nUsage: binget search <query> [-e]\n";
const list_help = "List installed packages.\nUsage: binget list [<query>] [-e]\n";
const which_help = "Locate the physical installation of a package.\nUsage: binget which <name>\n";
const sources_help = "Manage package repositories.\nUsage: binget sources update [--force]\n";
const shell_help = "Manage shell integration.\nUsage: binget shell <activate|hook> [<shell>]\n";
const exec_help = "Execute a command in the binget environment.\nUsage: binget exec <command> [<args>...]\n";
const new_help = "Initialize a new package.\nUsage: binget new\n";
const pack_help = "Pack a package into an archive.\nUsage: binget pack\n";
const trust_help = "Trust the current directory's binget.yaml.\nUsage: binget trust\n";
const scan_help = "Scan a package against VirusTotal.\nUsage: binget scan <name>[@version]\n";
const env_help = "Print the environment variables.\nUsage: binget env\n";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        const cmd = args[1];

        if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help")) {
            std.debug.print("{s}", .{global_help});
        } else if (std.mem.eql(u8, cmd, "install")) {
            const share_dir = try platform.getBingetShareDir(allocator);
            defer allocator.free(share_dir);
            try std.fs.cwd().makePath(share_dir);

            const db_path = try std.fs.path.join(allocator, &.{ share_dir, "binget.db" });
            defer allocator.free(db_path);
            const db_path_z = try allocator.dupeZ(u8, db_path);
            defer allocator.free(db_path_z);

            var db_conn = try db.Database.open(db_path_z);
            defer db_conn.close();

            const install_cmd = @import("install_cmd.zig");
            try install_cmd.parseAndRun(allocator, db_conn, args);
        } else if (std.mem.eql(u8, cmd, "add")) {
            const add_cmd = @import("add.zig");
            try add_cmd.parseAndRun(allocator, args);
        } else if (std.mem.eql(u8, cmd, "remove")) {
            const remove_cmd = @import("remove.zig");
            try remove_cmd.parseAndRun(allocator, args);
        } else if (std.mem.eql(u8, cmd, "search")) {
            const search_cmd = @import("search.zig");
            try search_cmd.parseAndRun(allocator, args);
        } else if (std.mem.eql(u8, cmd, "list")) {
            const list_cmd = @import("list.zig");
            try list_cmd.parseAndRun(allocator, args);
        } else if (std.mem.eql(u8, cmd, "which")) {
            const which_cmd = @import("which.zig");
            try which_cmd.parseAndRun(allocator, args);
        } else if (std.mem.eql(u8, cmd, "sources")) {
            const sources_cmd = @import("sources.zig");
            try sources_cmd.parseAndRun(allocator, args);
        } else if (std.mem.eql(u8, cmd, "shell")) {
            const shell_cmd = @import("shell.zig");
            try shell_cmd.parseAndRun(allocator, args);
        } else if (std.mem.eql(u8, cmd, "uninstall")) {
            if (args.len > 2 and (std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help"))) {
                std.debug.print("{s}", .{uninstall_help});
                return;
            }
            if (args.len < 3) {
                std.debug.print("{s}", .{uninstall_help});
                return;
            }
            const target = args[2];
            var skip_prompts: bool = false;
            if (args.len > 3) {
                for (args[3..]) |arg| {
                    if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
                        skip_prompts = true;
                    }
                }
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

            try uninstall.uninstallPackage(allocator, db_conn, target, skip_prompts);
        } else if (std.mem.eql(u8, cmd, "upgrade")) {
            if (args.len > 2 and (std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help"))) {
                std.debug.print("{s}", .{upgrade_help});
                return;
            }
            if (args.len < 3) {
                std.debug.print("{s}", .{upgrade_help});
                return;
            }
            const target = args[2];
            var global = false;
            var skip_prompts = false;
            if (args.len > 3) {
                for (args[3..]) |arg| {
                    if (std.mem.eql(u8, arg, "--global")) {
                        global = true;
                    } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y") or std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
                        skip_prompts = true;
                    }
                }
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

            try upgrade.upgradePackage(allocator, db_conn, target, global, skip_prompts);
        } else if (std.mem.eql(u8, cmd, "scan")) {
            if (args.len > 2 and (std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help"))) {
                std.debug.print("{s}", .{scan_help});
                return;
            }
            if (args.len < 3) {
                std.debug.print("{s}", .{scan_help});
                return;
            }

            const scan = @import("scan.zig");
            const target = args[2];

            var id: []const u8 = target;
            var version: ?[]const u8 = null;
            if (std.mem.indexOf(u8, target, "@")) |idx| {
                id = target[0..idx];
                version = target[idx + 1 ..];
            }

            scan.scanPackage(allocator, id, version) catch |err| {
                std.debug.print("Failed to scan package: {}\n", .{err});
            };
        } else if (std.mem.eql(u8, cmd, "env")) {
            if (args.len > 2 and (std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help"))) {
                std.debug.print("{s}", .{env_help});
                return;
            }
            const env = @import("env.zig");
            env.printEnv(allocator) catch |err| {
                if (err != error.NotTrusted) return err;
            };
        } else if (std.mem.eql(u8, cmd, "exec")) {
            if (args.len > 2 and (std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help"))) {
                std.debug.print("{s}", .{exec_help});
                return;
            }
            if (args.len < 3) {
                std.debug.print("{s}", .{exec_help});
                return;
            }
            const env = @import("env.zig");
            var pass_args = try allocator.alloc([]const u8, args.len - 2);
            defer allocator.free(pass_args);
            for (args[2..], 0..) |a, i| pass_args[i] = a;

            env.execCommand(allocator, pass_args) catch |err| {
                if (err != error.NotTrusted) return err;
            };
        } else if (std.mem.eql(u8, cmd, "new")) {
            if (args.len > 2 and (std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help"))) {
                std.debug.print("{s}", .{new_help});
                return;
            }
            const new_pkg = @import("new.zig");
            try new_pkg.initPackage(allocator);
        } else if (std.mem.eql(u8, cmd, "pack")) {
            if (args.len > 2 and (std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help"))) {
                std.debug.print("{s}", .{pack_help});
                return;
            }
            const pack = @import("pack.zig");
            try pack.packPackage(allocator);
        } else if (std.mem.eql(u8, cmd, "trust")) {
            if (args.len > 2 and (std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help"))) {
                std.debug.print("{s}", .{trust_help});
                return;
            }
            const trust = @import("trust.zig");
            try trust.trustCurrentDir(allocator);
        } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "-v") or std.mem.eql(u8, cmd, "--version")) {
            const version = @import("version.zig");
            version.printVersion();
        } else {
            std.debug.print("Command: {s}\n", .{cmd});
        }
    } else {
        std.debug.print("{s}", .{global_help});
    }
}
