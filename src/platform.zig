const std = @import("std");

pub const ShellType = enum {
    bash,
    zsh,
    fish,
    powershell, // Windows PowerShell
    pwsh, // PowerShell Core (cross-platform)
    cmd,
    sh,
    unknown,
};

/// Format a given absolute path for the target shell and OS combination.
pub fn formatPathForShell(allocator: std.mem.Allocator, path: []const u8, shell: ShellType, os: std.Target.Os.Tag) ![]u8 {
    var formatted = try allocator.alloc(u8, path.len + 3); // Extra space for possible /c/ replacement
    errdefer allocator.free(formatted);
    var len: usize = 0;

    if (os == .windows) {
        if (shell == .bash or shell == .zsh or shell == .fish or shell == .sh) {
            // Git Bash / MSYS2 style paths: C:\Users\... -> /c/Users/...
            if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') {
                formatted[0] = '/';
                formatted[1] = std.ascii.toLower(path[0]);
                len = 2;

                var i: usize = 2;
                while (i < path.len) : (i += 1) {
                    const c = path[i];
                    if (c == '\\') {
                        formatted[len] = '/';
                    } else {
                        formatted[len] = c;
                    }
                    len += 1;
                }
            } else {
                // Just flip slashes
                for (path) |c| {
                    if (c == '\\') {
                        formatted[len] = '/';
                    } else {
                        formatted[len] = c;
                    }
                    len += 1;
                }
            }
            return allocator.realloc(formatted, len);
        } else if (shell == .pwsh or shell == .powershell) {
            // Powershell generally likes forward slashes or backslashes. Let's use backslashes.
            for (path) |c| {
                if (c == '/') {
                    formatted[len] = '\\';
                } else {
                    formatted[len] = c;
                }
                len += 1;
            }
            return allocator.realloc(formatted, len);
        }
    } else {
        // macOS / Linux
        // Just copy over, but if it's pwsh/powershell, it might prefer forward slashes which is standard anyway.
        for (path) |c| {
            if (c == '\\') {
                formatted[len] = '/';
            } else {
                formatted[len] = c;
            }
            len += 1;
        }
        return allocator.realloc(formatted, len);
    }

    // Default fallback
    @memcpy(formatted[0..path.len], path);
    return allocator.realloc(formatted, path.len);
}

/// Detect the shell from the environment
pub fn detectShell(allocator: std.mem.Allocator) !ShellType {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const shell_env = env_map.get("SHELL") orelse "";
    if (std.mem.endsWith(u8, shell_env, "bash")) return .bash;
    if (std.mem.endsWith(u8, shell_env, "zsh")) return .zsh;
    if (std.mem.endsWith(u8, shell_env, "fish")) return .fish;
    if (std.mem.endsWith(u8, shell_env, "pwsh")) return .pwsh;
    if (std.mem.endsWith(u8, shell_env, "sh")) return .sh;

    if (env_map.get("PSModulePath") != null) return .powershell;
    if (env_map.get("COMSPEC") != null) return .cmd;
    return .unknown;
}

pub fn getInstallDir(allocator: std.mem.Allocator, global: bool) ![]const u8 {
    const builtin = @import("builtin");
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    if (env_map.get("BINGET_BIN")) |bin_dir| {
        return allocator.dupe(u8, bin_dir);
    }

    if (global) {
        if (builtin.os.tag == .windows) {
            return std.fs.path.join(allocator, &.{ "C:\\Program Files", "bin" });
        } else {
            return allocator.dupe(u8, "/usr/local/bin");
        }
    } else {
        if (builtin.os.tag == .windows) {
            const appdata = env_map.get("LOCALAPPDATA") orelse try std.fs.path.join(allocator, &.{ env_map.get("USERPROFILE") orelse "C:\\", "AppData", "Local" });
            return std.fs.path.join(allocator, &.{ appdata, "Programs", "bin" });
        } else {
            const home = env_map.get("HOME") orelse "/tmp";
            return std.fs.path.join(allocator, &.{ home, ".local", "bin" });
        }
    }
}

pub fn getBingetConfigDir(allocator: std.mem.Allocator) ![]const u8 {
    const builtin = @import("builtin");
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    if (env_map.get("BINGET_CONFIG_ROOT")) |root| {
        return allocator.dupe(u8, root);
    }

    if (builtin.os.tag == .windows) {
        const appdata = env_map.get("APPDATA") orelse try std.fs.path.join(allocator, &.{ env_map.get("USERPROFILE") orelse "C:\\", "AppData", "Roaming" });
        return std.fs.path.join(allocator, &.{ appdata, "binget" });
    } else {
        const config_home = env_map.get("XDG_CONFIG_HOME") orelse try std.fs.path.join(allocator, &.{ env_map.get("HOME") orelse "/tmp", ".config" });
        return std.fs.path.join(allocator, &.{ config_home, "binget" });
    }
}

pub fn getBingetShareDir(allocator: std.mem.Allocator) ![]const u8 {
    const builtin = @import("builtin");
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    if (env_map.get("BINGET_ROOT")) |root| {
        return allocator.dupe(u8, root);
    }

    if (builtin.os.tag == .windows) {
        const appdata = env_map.get("LOCALAPPDATA") orelse try std.fs.path.join(allocator, &.{ env_map.get("USERPROFILE") orelse "C:\\", "AppData", "Local" });
        return std.fs.path.join(allocator, &.{ appdata, "binget" });
    } else {
        const home = env_map.get("HOME") orelse "/tmp";
        return std.fs.path.join(allocator, &.{ home, ".local", "share", "binget" });
    }
}

pub fn isAdmin() bool {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        var child = std.process.Child.init(&[_][]const u8{ "net", "session" }, std.heap.page_allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        const term = child.spawnAndWait() catch return false;
        switch (term) {
            .Exited => |code| return code == 0,
            else => return false,
        }
    } else {
        return std.posix.geteuid() == 0;
    }
}

pub fn hasSudo(allocator: std.mem.Allocator) bool {
    var child = std.process.Child.init(&[_][]const u8{ "sudo", "--version" }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch return false;
    switch (term) {
        .Exited => |code| return code == 0,
        else => return false,
    }
}

pub fn getHomeDir(allocator: std.mem.Allocator) ![]const u8 {
    const builtin = @import("builtin");
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    if (builtin.os.tag == .windows) {
        if (env_map.get("USERPROFILE")) |p| {
            return allocator.dupe(u8, p);
        }
    } else {
        if (env_map.get("HOME")) |p| {
            return allocator.dupe(u8, p);
        }
    }
    return error.EnvironmentVariableNotFound;
}
