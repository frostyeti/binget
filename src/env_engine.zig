const std = @import("std");
const binget_file = @import("binget_file.zig");

pub const EnvMap = std.StringArrayHashMap([]const u8);

pub fn evaluate(allocator: std.mem.Allocator, binget_dir: []const u8, file: *const binget_file.BingetFile) !EnvMap {
    var env = EnvMap.init(allocator);
    errdefer {
        var it = env.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        env.deinit();
    }

    var system_env = try std.process.getEnvMap(allocator);
    defer system_env.deinit();

    // 1. Process dotenv
    for (file.dotenv_paths.items) |dotenv_path| {
        var is_optional = false;
        var actual_path = dotenv_path;
        if (std.mem.endsWith(u8, actual_path, "?")) {
            is_optional = true;
            actual_path = actual_path[0 .. actual_path.len - 1];
        }

        const full_path = try std.fs.path.join(allocator, &.{ binget_dir, actual_path });
        defer allocator.free(full_path);

        var dotenv_file = std.fs.cwd().openFile(full_path, .{}) catch |err| {
            if (is_optional and err == error.FileNotFound) {
                continue;
            }
            return err;
        };
        defer dotenv_file.close();

        const content = try dotenv_file.readToEndAlloc(allocator, 10 * 1024 * 1024);
        defer allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_idx| {
                const key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
                var val = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");
                if (val.len > 0 and (val[0] == '"' or val[0] == '\'')) {
                    const q = val[0];
                    val = val[1..];
                    if (std.mem.lastIndexOfScalar(u8, val, q)) |end_idx| {
                        val = val[0..end_idx];
                    }
                }
                
                try env.put(try allocator.dupe(u8, key), try allocator.dupe(u8, val));
            }
        }
    }

    // 2. Process env
    for (file.env_vars.items) |v| {
        const interpolated = try interpolate(allocator, v.value, &env, &system_env, binget_dir);
        try env.put(try allocator.dupe(u8, v.key), interpolated);
    }

    return env;
}

fn interpolate(allocator: std.mem.Allocator, input: []const u8, env: *EnvMap, sys: *std.process.EnvMap, work_dir: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '$' and i + 1 < input.len) {
            if (input[i+1] == '{') {
                // ${VAR} or ${VAR:-default}
                const start = i + 2;
                var end = start;
                while (end < input.len and input[end] != '}') : (end += 1) {}
                
                if (end < input.len) {
                    const inner = input[start..end];
                    var var_name = inner;
                    var default_val: ?[]const u8 = null;
                    
                    if (std.mem.indexOf(u8, inner, ":-")) |def_idx| {
                        var_name = inner[0..def_idx];
                        default_val = inner[def_idx + 2 ..];
                    }
                    
                    if (env.get(var_name) orelse sys.get(var_name)) |val| {
                        try result.appendSlice(allocator, val);
                    } else if (default_val) |def| {
                        try result.appendSlice(allocator, def);
                    }
                    i = end + 1;
                    continue;
                }
            } else if (input[i+1] == '(') {
                // $(cmd)
                const start = i + 2;
                var end = start;
                var paren_count: usize = 1;
                while (end < input.len) : (end += 1) {
                    if (input[end] == '(') paren_count += 1;
                    if (input[end] == ')') {
                        paren_count -= 1;
                        if (paren_count == 0) break;
                    }
                }
                
                if (end < input.len) {
                    const cmd = input[start..end];
                    const out = try execCommand(allocator, cmd, work_dir);
                    defer allocator.free(out);
                    
                    // trim trailing newline
                    const trimmed = std.mem.trimRight(u8, out, "\r\n");
                    try result.appendSlice(allocator, trimmed);
                    
                    i = end + 1;
                    continue;
                }
            } else {
                // simple $VAR
                const start = i + 1;
                var end = start;
                while (end < input.len and (std.ascii.isAlphanumeric(input[end]) or input[end] == '_')) : (end += 1) {}
                
                if (end > start) {
                    const var_name = input[start..end];
                    if (env.get(var_name) orelse sys.get(var_name)) |val| {
                        try result.appendSlice(allocator, val);
                    }
                    i = end;
                    continue;
                }
            }
        }
        
        try result.append(allocator, input[i]);
        i += 1;
    }
    
    return result.toOwnedSlice(allocator);
}

fn execCommand(allocator: std.mem.Allocator, cmd: []const u8, work_dir: []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    
    try argv.append(allocator, "sh");
    try argv.append(allocator, "-c");
    try argv.append(allocator, cmd);
    
    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = work_dir;
    
    var stdout = std.ArrayList(u8).empty;
    defer stdout.deinit(allocator);
    
    var stderr = std.ArrayList(u8).empty;
    defer stderr.deinit(allocator);
    
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    try child.collectOutput(allocator, &stdout, &stderr, 10 * 1024 * 1024);
    
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("Command failed: {s}\nStderr: {s}\n", .{ cmd, stderr.items });
        return error.CommandFailed;
    }
    
    return stdout.toOwnedSlice(allocator);
}

test "env_engine interpolation" {
    var sys = std.process.EnvMap.init(std.testing.allocator);
    defer sys.deinit();
    try sys.put("SYS_VAR", "sys_val");
    
    var env = EnvMap.init(std.testing.allocator);
    defer {
        var it = env.iterator();
        while (it.next()) |e| {
            std.testing.allocator.free(e.key_ptr.*);
            std.testing.allocator.free(e.value_ptr.*);
        }
        env.deinit();
    }
    try env.put(try std.testing.allocator.dupe(u8, "LOCAL_VAR"), try std.testing.allocator.dupe(u8, "local_val"));
    
    const s1 = try interpolate(std.testing.allocator, "${LOCAL_VAR}", &env, &sys, ".");
    defer std.testing.allocator.free(s1);
    try std.testing.expectEqualStrings("local_val", s1);
    
    const s2 = try interpolate(std.testing.allocator, "${SYS_VAR}", &env, &sys, ".");
    defer std.testing.allocator.free(s2);
    try std.testing.expectEqualStrings("sys_val", s2);
    
    const s3 = try interpolate(std.testing.allocator, "${MISSING:-def}", &env, &sys, ".");
    defer std.testing.allocator.free(s3);
    try std.testing.expectEqualStrings("def", s3);
    
    const s4 = try interpolate(std.testing.allocator, "$(echo hello)", &env, &sys, ".");
    defer std.testing.allocator.free(s4);
    try std.testing.expectEqualStrings("hello", s4);
    
    const s5 = try interpolate(std.testing.allocator, "$LOCAL_VAR/test", &env, &sys, ".");
    defer std.testing.allocator.free(s5);
    try std.testing.expectEqualStrings("local_val/test", s5);
}
