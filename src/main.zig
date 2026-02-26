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
    \\  install          Install a package from a repository
    \\  upk              Install a package from a local meta.yaml file
    \\  uninstall        Uninstall a package
    \\  upgrade          Upgrade an installed package
    \\  scan             Scan a package against VirusTotal
    \\  env              Print the environment variables
    \\  shell-activate   Activate the shell environment
    \\  exec             Execute a command in the binget environment
    \\  init             Initialize a new package
    \\  pack             Pack a package into an archive
    \\  trust            Trust the current directory's binget.yaml
    \\  shell-hook       Print the shell hook for setting PATH
    \\  version          Print the version
    \\
    \\Options:
    \\  -h, --help       Show this help message and exit
    \\  -v, --version    Show version and exit
    \\
;

const install_help =
    \\Install a package from a repository.
    \\
    \\Usage:
    \\  binget install <owner/repo> [--global]
    \\  binget install -h | --help
    \\
    \\Options:
    \\  --global         Install globally
    \\  -h, --help       Show this help message and exit
    \\
;

const upk_help =
    \\Install a package from a local meta.yaml file.
    \\
    \\Usage:
    \\  binget upk <meta.yaml> [--global]
    \\  binget upk -h | --help
    \\
    \\Options:
    \\  --global         Install globally
    \\  -h, --help       Show this help message and exit
    \\
;

const uninstall_help =
    \\Uninstall a package.
    \\
    \\Usage:
    \\  binget uninstall <name> [--yes]
    \\  binget uninstall -h | --help
    \\
    \\Options:
    \\  -h, --help       Show this help message and exit
    \\  -y, --yes        Skip prompts for hooks
    \\  -f, --force      Skip prompts for hooks
    \\
;

const upgrade_help =
    \\Upgrade an installed package.
    \\
    \\Usage:
    \\  binget upgrade <name> [--global]
    \\  binget upgrade -h | --help
    \\
    \\Options:
    \\  --global         Upgrade globally
    \\  -h, --help       Show this help message and exit
    \\
;

const scan_help =
    \\Scan a package against VirusTotal.
    \\
    \\Usage:
    \\  binget scan <name>[@version]
    \\  binget scan -h | --help
    \\
    \\Environment Variables:
    \\  VT_API_KEY       Your VirusTotal API key (required)
    \\
    \\Options:
    \\  -h, --help       Show this help message and exit
    \\
;

const env_help =
    \\Print the environment variables.
    \\
    \\Usage:
    \\  binget env
    \\  binget env -h | --help
    \\
    \\Options:
    \\  -h, --help       Show this help message and exit
    \\
;

const shell_activate_help =
    \\Activate the shell environment.
    \\
    \\Usage:
    \\  binget shell-activate <bash|zsh|fish|pwsh>
    \\  binget shell-activate -h | --help
    \\
    \\Options:
    \\  -h, --help       Show this help message and exit
    \\
;

const exec_help =
    \\Execute a command in the binget environment.
    \\
    \\Usage:
    \\  binget exec <command> [<args>...]
    \\  binget exec -h | --help
    \\
    \\Options:
    \\  -h, --help       Show this help message and exit
    \\
;

const init_help =
    \\Initialize a new package.
    \\
    \\Usage:
    \\  binget init
    \\  binget init -h | --help
    \\
    \\Options:
    \\  -h, --help       Show this help message and exit
    \\
;

const pack_help =
    \\Pack a package into an archive.
    \\
    \\Usage:
    \\  binget pack
    \\  binget pack -h | --help
    \\
    \\Options:
    \\  -h, --help       Show this help message and exit
    \\
;

const trust_help =
    \\Trust the current directory's binget.yaml.
    \\
    \\Usage:
    \\  binget trust
    \\  binget trust -h | --help
    \\
    \\Options:
    \\  -h, --help       Show this help message and exit
    \\
;

const shell_hook_help =
    \\Print the shell hook for setting PATH.
    \\
    \\Usage:
    \\  binget shell-hook
    \\  binget shell-hook -h | --help
    \\
    \\Options:
    \\  -h, --help       Show this help message and exit
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) {
            std.debug.print("{s}", .{global_help});
        } else if (std.mem.eql(u8, args[1], "install")) {
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
        } else if (std.mem.eql(u8, args[1], "upk")) {
            if (args.len > 2 and (std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help"))) {
                std.debug.print("{s}", .{upk_help});
                return;
            }
            if (args.len < 3) {
                std.debug.print("{s}", .{upk_help});
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

            const upk = @import("upk.zig");
            try upk.installUpk(allocator, db_conn, target, global);
        } else if (std.mem.eql(u8, args[1], "uninstall")) {
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
        } else if (std.mem.eql(u8, args[1], "upgrade")) {
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
        } else if (std.mem.eql(u8, args[1], "scan")) {
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
        } else if (std.mem.eql(u8, args[1], "env")) {
            if (args.len > 2 and (std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help"))) {
                std.debug.print("{s}", .{env_help});
                return;
            }
            const env = @import("env.zig");
            env.printEnv(allocator) catch |err| {
                if (err != error.NotTrusted) return err;
            };
        } else if (std.mem.eql(u8, args[1], "shell-activate")) {
            if (args.len > 2 and (std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help"))) {
                std.debug.print("{s}", .{shell_activate_help});
                return;
            }
            if (args.len < 3) {
                std.debug.print("{s}", .{shell_activate_help});
                return;
            }
            const shell = args[2];
            const env = @import("env.zig");
            env.shellActivate(allocator, shell) catch |err| {
                if (err != error.NotTrusted) return err;
            };
        } else if (std.mem.eql(u8, args[1], "exec")) {
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
        } else if (std.mem.eql(u8, args[1], "init")) {
            if (args.len > 2 and (std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help"))) {
                std.debug.print("{s}", .{init_help});
                return;
            }
            const init_pkg = @import("init_pkg.zig");
            try init_pkg.initPackage(allocator);
        } else if (std.mem.eql(u8, args[1], "pack")) {
            if (args.len > 2 and (std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help"))) {
                std.debug.print("{s}", .{pack_help});
                return;
            }
            const pack = @import("pack.zig");
            try pack.packPackage(allocator);
        } else if (std.mem.eql(u8, args[1], "trust")) {
            if (args.len > 2 and (std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help"))) {
                std.debug.print("{s}", .{trust_help});
                return;
            }
            const trust = @import("trust.zig");
            try trust.trustCurrentDir(allocator);
        } else if (std.mem.eql(u8, args[1], "version") or std.mem.eql(u8, args[1], "-v") or std.mem.eql(u8, args[1], "--version")) {
            const version = @import("version.zig");
            version.printVersion();
        } else if (std.mem.eql(u8, args[1], "shell-hook")) {
            if (args.len > 2 and (std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help"))) {
                std.debug.print("{s}", .{shell_hook_help});
                return;
            }
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
        std.debug.print("{s}", .{global_help});
    }
}
