const std = @import("std");
const registry = @import("registry.zig");
const platform = @import("platform.zig");
const install_cmd = @import("install_cmd.zig");

pub fn applyRegistryKeys(allocator: std.mem.Allocator, keys: []const registry.RegistryKey, mode: install_cmd.InstallMode) !void {
    _ = mode;
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return;

    for (keys) |key| {
        // If the path starts with HKLM or HKCR, we might need admin
        if (std.mem.startsWith(u8, key.path, "HKLM") or std.mem.startsWith(u8, key.path, "HKCR")) {
            if (!platform.isAdmin()) {
                std.debug.print("Error: Administrator privileges required to modify registry key: {s}\n", .{key.path});
                return error.AccessDenied;
            }
        }

        if (key.remove != null and key.remove.?) {
            // reg delete "path" [/v "name"] /f
            var args = std.ArrayList([]const u8).empty;
            defer args.deinit(allocator);

            try args.append(allocator, "reg");
            try args.append(allocator, "delete");
            try args.append(allocator, key.path);

            if (key.name) |n| {
                try args.append(allocator, "/v");
                try args.append(allocator, n);
            }

            try args.append(allocator, "/f");

            var child = std.process.Child.init(args.items, allocator);
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Inherit;
            const term = try child.spawnAndWait();
            if (term != .Exited or term.Exited != 0) {
                std.debug.print("Warning: Failed to delete registry key: {s}\n", .{key.path});
            } else {
                std.debug.print("Removed registry key: {s}\n", .{key.path});
            }
        } else {
            // reg add "path" [/v "name"] [/t "type"] [/d "value"] /f
            var args = std.ArrayList([]const u8).empty;
            defer args.deinit(allocator);

            try args.append(allocator, "reg");
            try args.append(allocator, "add");
            try args.append(allocator, key.path);

            if (key.name) |n| {
                try args.append(allocator, "/v");
                try args.append(allocator, n);
            }

            if (key.type) |t| {
                try args.append(allocator, "/t");
                try args.append(allocator, t);
            }

            if (key.value) |v| {
                try args.append(allocator, "/d");
                try args.append(allocator, v);
            }

            try args.append(allocator, "/f");

            var child = std.process.Child.init(args.items, allocator);
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Inherit;
            const term = try child.spawnAndWait();
            if (term != .Exited or term.Exited != 0) {
                std.debug.print("Warning: Failed to add registry key: {s}\n", .{key.path});
                return error.RegistryError;
            } else {
                std.debug.print("Set registry key: {s}\n", .{key.path});
            }
        }
    }
}
