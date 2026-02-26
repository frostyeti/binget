const std = @import("std");
const registry = @import("registry.zig");
const install_cmd = @import("install_cmd.zig");
const windows_utils = @import("windows_utils.zig");
const platform = @import("platform.zig");

pub fn run(allocator: std.mem.Allocator, id: []const u8, version: []const u8, config: registry.InstallModeConfig, mode: install_cmd.InstallMode) !void {
    _ = id;
    _ = version;

    if (config.registry_keys) |keys| {
        try windows_utils.applyRegistryKeys(allocator, keys, mode);
    }

    if (config.links) |links| {
        try applyLinks(allocator, links);
    }

    if (config.shortcuts) |shortcuts| {
        try applyShortcuts(allocator, shortcuts);
    }
}

fn applyLinks(allocator: std.mem.Allocator, links: []const registry.Link) !void {
    _ = allocator;
    for (links) |l| {
        std.debug.print("Creating {s}: {s} -> {s}\n", .{ l.type, l.link, l.target });
        if (std.mem.eql(u8, l.type, "symlink")) {
            std.fs.cwd().symLink(l.target, l.link, .{}) catch |err| {
                std.debug.print("Warning: Failed to create symlink {s}: {}\n", .{ l.link, err });
            };
        } else if (std.mem.eql(u8, l.type, "hardlink")) {
            const builtin = @import("builtin");
            if (builtin.os.tag == .windows) {
                // Not supported natively in std.posix.link for Windows yet. Fallback to copy or log warning.
                std.debug.print("Warning: Hardlinks are not natively supported on Windows via std.posix.link. Using copy instead.\n", .{});
                std.fs.cwd().copyFile(l.target, std.fs.cwd(), l.link, .{}) catch |err| {
                    std.debug.print("Warning: Failed to copy file {s}: {}\n", .{ l.link, err });
                };
            } else {
                std.posix.link(l.target, l.link) catch |err| {
                    std.debug.print("Warning: Failed to create hardlink {s}: {}\n", .{ l.link, err });
                };
            }
        }
    }
}

fn applyShortcuts(allocator: std.mem.Allocator, shortcuts: []const registry.Shortcut) !void {
    const builtin = @import("builtin");

    for (shortcuts) |shortcut| {
        std.debug.print("Creating shortcut: {s}\n", .{shortcut.name});

        if (builtin.os.tag == .windows) {
            // Use PowerShell to create a .lnk shortcut
            var script = std.ArrayList(u8).empty;
            defer script.deinit(allocator);

            // Handle location (desktop, menu, etc)
            // Desktop: [Environment]::GetFolderPath("Desktop")
            // Start Menu: [Environment]::GetFolderPath("StartMenu") or "Programs"
            var folder_var: []const u8 = "Desktop";
            if (std.mem.eql(u8, shortcut.location, "menu")) {
                folder_var = "Programs";
            }

            try script.writer(allocator).print(
                \\$WshShell = New-Object -comObject WScript.Shell
                \\$path = [Environment]::GetFolderPath("{s}")
                \\$shortcut = $WshShell.CreateShortcut($path + "\{s}.lnk")
                \\$shortcut.TargetPath = "{s}"
                \\$shortcut.Save()
            , .{ folder_var, shortcut.name, shortcut.target });

            var child = std.process.Child.init(&[_][]const u8{ "powershell", "-NoProfile", "-Command", script.items }, allocator);
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Inherit;
            _ = try child.spawnAndWait();
        } else if (builtin.os.tag == .linux) {
            // Create a .desktop file
            var path = std.ArrayList(u8).empty;
            defer path.deinit(allocator);

            const home = std.posix.getenv("HOME") orelse return error.NoHome;
            if (std.mem.eql(u8, shortcut.location, "desktop")) {
                try path.writer(allocator).print("{s}/Desktop/{s}.desktop", .{ home, shortcut.name });
            } else {
                try path.writer(allocator).print("{s}/.local/share/applications/{s}.desktop", .{ home, shortcut.name });
            }

            try std.fs.cwd().makePath(std.fs.path.dirname(path.items).?);
            var file = try std.fs.cwd().createFile(path.items, .{});
            defer file.close();

            const content = try std.fmt.allocPrint(allocator,
                \\[Desktop Entry]
                \\Name={s}
                \\Exec={s}
                \\Type=Application
                \\Terminal=false
                \\
            , .{ shortcut.name, shortcut.target });
            defer allocator.free(content);
            try file.writeAll(content);

            if (shortcut.icon) |ic| {
                const icon_str = try std.fmt.allocPrint(allocator, "Icon={s}\n", .{ic});
                defer allocator.free(icon_str);
                try file.writeAll(icon_str);
            }

            // Make executable if on desktop
            if (std.mem.eql(u8, shortcut.location, "desktop")) {
                const stat = try file.stat();
                try file.chmod(stat.mode | 0o111);
            }
        } else if (builtin.os.tag == .macos) {
            // Symlink to Applications or Desktop
            var path = std.ArrayList(u8).empty;
            defer path.deinit(allocator);

            const home = std.posix.getenv("HOME") orelse return error.NoHome;
            if (std.mem.eql(u8, shortcut.location, "desktop")) {
                try path.writer(allocator).print("{s}/Desktop/{s}", .{ home, shortcut.name });
            } else {
                try path.writer(allocator).print("{s}/Applications/{s}", .{ home, shortcut.name });
            }

            // It's common to symlink .app folders. We'll just do a symlink.
            std.fs.cwd().deleteFile(path.items) catch {};
            std.fs.cwd().deleteTree(path.items) catch {}; // in case it's a directory symlink
            std.fs.cwd().symLink(shortcut.target, path.items, .{}) catch |err| {
                std.debug.print("Warning: Failed to create macOS shortcut {s}: {}\n", .{ path.items, err });
            };
        }
    }
}
