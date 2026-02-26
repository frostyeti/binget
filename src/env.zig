const std = @import("std");
const platform = @import("platform.zig");
const binget_file = @import("binget_file.zig");
const env_engine = @import("env_engine.zig");
const trust = @import("trust.zig");

pub fn findConfig(allocator: std.mem.Allocator) !?[]const u8 {
    var curr_dir = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(curr_dir);

    while (true) {
        const conf_path = try std.fs.path.join(allocator, &.{ curr_dir, ".binget" });
        defer allocator.free(conf_path);

        if (std.fs.cwd().access(conf_path, .{})) |_| {
            return try allocator.dupe(u8, conf_path);
        } else |_| {}

        const conf_path_yaml = try std.fs.path.join(allocator, &.{ curr_dir, ".binget.yaml" });
        defer allocator.free(conf_path_yaml);

        if (std.fs.cwd().access(conf_path_yaml, .{})) |_| {
            return try allocator.dupe(u8, conf_path_yaml);
        } else |_| {}

        const parent = std.fs.path.dirname(curr_dir);
        if (parent == null or std.mem.eql(u8, parent.?, curr_dir)) {
            break;
        }
        
        const next_dir = try allocator.dupe(u8, parent.?);
        allocator.free(curr_dir);
        curr_dir = next_dir;
    }
    return null;
}

pub fn loadAndEvaluate(allocator: std.mem.Allocator) !?env_engine.EnvMap {
    const config_path = try findConfig(allocator);
    if (config_path == null) return null;
    defer allocator.free(config_path.?);

    const config_dir = std.fs.path.dirname(config_path.?).?;

    // Check trust
    if (!(try trust.isTrusted(allocator, config_dir))) {
        std.debug.print("Error: Directory is not trusted. Run `binget trust` in {s} to execute its .binget file.\n", .{config_dir});
        return error.NotTrusted;
    }

    var file = try std.fs.cwd().openFile(config_path.?, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var bf = try binget_file.parseBingetFile(allocator, content);
    defer bf.deinit();

    return try env_engine.evaluate(allocator, config_dir, &bf);
}

pub fn printEnv(allocator: std.mem.Allocator) !void {
    if (try loadAndEvaluate(allocator)) |var_map| {
        var it = var_map.iterator();
        while (it.next()) |entry| {
            std.debug.print("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        var map = var_map;
        var map_it = map.iterator();
        while (map_it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        map.deinit();
    }
}

pub fn shellActivate(allocator: std.mem.Allocator, shell_name: []const u8) !void {
    if (try loadAndEvaluate(allocator)) |var_map| {
        var map = var_map;
        defer {
            var map_it = map.iterator();
            while (map_it.next()) |e| {
                allocator.free(e.key_ptr.*);
                allocator.free(e.value_ptr.*);
            }
            map.deinit();
        }

        var it = map.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, shell_name, "bash") or std.mem.eql(u8, shell_name, "zsh")) {
                std.debug.print("export {s}=\"{s}\"\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            } else if (std.mem.eql(u8, shell_name, "fish")) {
                std.debug.print("set -gx {s} \"{s}\"\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            } else if (std.mem.eql(u8, shell_name, "powershell") or std.mem.eql(u8, shell_name, "pwsh")) {
                std.debug.print("$env:{s} = \"{s}\"\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }
    }
}

pub fn execCommand(allocator: std.mem.Allocator, args: [][]const u8) !void {
    if (args.len == 0) return;

    var child = std.process.Child.init(args, allocator);
    
    var custom_env = try std.process.getEnvMap(allocator);
    defer custom_env.deinit();

    if (try loadAndEvaluate(allocator)) |var_map| {
        var map = var_map;
        defer {
            var map_it = map.iterator();
            while (map_it.next()) |e| {
                allocator.free(e.key_ptr.*);
                allocator.free(e.value_ptr.*);
            }
            map.deinit();
        }

        var it = map.iterator();
        while (it.next()) |entry| {
            try custom_env.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    child.env_map = &custom_env;

    const term = try child.spawnAndWait();
    if (term != .Exited) {
        std.process.exit(1);
    }
    std.process.exit(term.Exited);
}
