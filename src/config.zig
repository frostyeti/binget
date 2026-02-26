const std = @import("std");
const platform = @import("platform.zig");

pub const Config = struct {
    script_extension_preference: [][]const u8,

    pub fn initDefault(allocator: std.mem.Allocator) !Config {
        const builtin = @import("builtin");
        const default_exts = if (builtin.os.tag == .windows)
            [_][]const u8{ ".ts", ".ps1", ".sh" }
        else
            [_][]const u8{ ".sh", ".ps1", ".ts" };

        var exts = std.ArrayList([]const u8).empty;
        for (default_exts) |ext| {
            try exts.append(allocator, try allocator.dupe(u8, ext));
        }

        return Config{
            .script_extension_preference = try exts.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.script_extension_preference) |ext| {
            allocator.free(ext);
        }
        allocator.free(self.script_extension_preference);
    }
};

pub fn loadConfig(allocator: std.mem.Allocator) !Config {
    const config_dir = platform.getBingetConfigDir(allocator) catch |err| {
        std.debug.print("Warning: Could not get config dir: {any}\n", .{err});
        return Config.initDefault(allocator);
    };
    defer allocator.free(config_dir);

    const config_path = try std.fs.path.join(allocator, &.{ config_dir, "config.json" });
    defer allocator.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch {
        // Return default config if file doesn't exist
        return Config.initDefault(allocator);
    };
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size > 1024 * 1024) {
        return error.ConfigFileTooLarge;
    }

    const content = try file.readToEndAlloc(allocator, @intCast(file_size));
    defer allocator.free(content);

    const ParsedConfig = struct {
        script_extension_preference: ?[][]const u8 = null,
    };

    const parsed = std.json.parseFromSlice(ParsedConfig, allocator, content, .{ .ignore_unknown_fields = true }) catch {
        std.debug.print("Warning: Failed to parse config.json, using defaults.\n", .{});
        return Config.initDefault(allocator);
    };
    defer parsed.deinit();

    if (parsed.value.script_extension_preference) |exts| {
        var new_exts = std.ArrayList([]const u8).empty;
        for (exts) |ext| {
            try new_exts.append(allocator, try allocator.dupe(u8, ext));
        }
        return Config{
            .script_extension_preference = try new_exts.toOwnedSlice(allocator),
        };
    }

    return Config.initDefault(allocator);
}
