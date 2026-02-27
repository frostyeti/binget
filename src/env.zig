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

pub fn loadAndEvaluate(allocator: std.mem.Allocator, sys_env: ?*std.process.EnvMap) !?env_engine.EnvMap {
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

    var system_env = if (sys_env) |s| s.* else try std.process.getEnvMap(allocator);
    defer if (sys_env == null) system_env.deinit();

    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);
    const db_path = try std.fs.path.join(allocator, &.{ share_dir, "binget.db" });
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    var db_conn = try @import("db.zig").Database.open(db_path_z);
    defer db_conn.close();

    return try env_engine.evaluate(allocator, db_conn, config_dir, &bf, &system_env);
}

pub fn printEnv(allocator: std.mem.Allocator) !void {
    if (try loadAndEvaluate(allocator, null)) |var_map| {
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

pub fn execCommand(allocator: std.mem.Allocator, args: [][]const u8) !void {
    if (args.len == 0) return;

    var child = std.process.Child.init(args, allocator);

    var custom_env = try std.process.getEnvMap(allocator);
    defer custom_env.deinit();

    if (try loadAndEvaluate(allocator, null)) |var_map| {
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
fn printUnset(allocator: std.mem.Allocator, shell_name: []const u8, var_name: []const u8) void {
    const stdout = std.fs.File.stdout();
    if (std.mem.eql(u8, shell_name, "bash") or std.mem.eql(u8, shell_name, "zsh") or std.mem.eql(u8, shell_name, "sh")) {
        if (std.fmt.allocPrint(allocator, "unset {s}\n", .{var_name})) |msg| {
            stdout.writeAll(msg) catch {};
            allocator.free(msg);
        } else |_| {}
    } else if (std.mem.eql(u8, shell_name, "fish")) {
        if (std.fmt.allocPrint(allocator, "set -e {s}\n", .{var_name})) |msg| {
            stdout.writeAll(msg) catch {};
            allocator.free(msg);
        } else |_| {}
    } else if (std.mem.eql(u8, shell_name, "powershell") or std.mem.eql(u8, shell_name, "pwsh")) {
        if (std.fmt.allocPrint(allocator, "Remove-Item Env:\\{s}\n", .{var_name})) |msg| {
            stdout.writeAll(msg) catch {};
            allocator.free(msg);
        } else |_| {}
    }
}

fn printExport(allocator: std.mem.Allocator, shell_name: []const u8, var_name: []const u8, value: []const u8) void {
    const stdout = std.fs.File.stdout();
    if (std.mem.eql(u8, shell_name, "bash") or std.mem.eql(u8, shell_name, "zsh") or std.mem.eql(u8, shell_name, "sh")) {
        if (std.fmt.allocPrint(allocator, "export {s}=\"{s}\"\n", .{ var_name, value })) |msg| {
            stdout.writeAll(msg) catch {};
            allocator.free(msg);
        } else |_| {}
    } else if (std.mem.eql(u8, shell_name, "fish")) {
        if (std.fmt.allocPrint(allocator, "set -gx {s} \"{s}\"\n", .{ var_name, value })) |msg| {
            stdout.writeAll(msg) catch {};
            allocator.free(msg);
        } else |_| {}
    } else if (std.mem.eql(u8, shell_name, "powershell") or std.mem.eql(u8, shell_name, "pwsh")) {
        if (std.fmt.allocPrint(allocator, "$env:{s} = \"{s}\"\n", .{ var_name, value })) |msg| {
            stdout.writeAll(msg) catch {};
            allocator.free(msg);
        } else |_| {}
    }
}

pub fn shellActivate(allocator: std.mem.Allocator, shell_name: []const u8) !void {
    _ = allocator;
    const stdout = std.fs.File.stdout();
    if (std.mem.eql(u8, shell_name, "bash")) {
        stdout.writeAll(
            \\binget() {
            \\  local command_name=$1
            \\  command binget "$@"
            \\  local exit_code=$?
            \\  case "$command_name" in
            \\    install|add|remove|upgrade|uninstall)
            \\      eval "$(command binget shell compute bash)"
            \\      hash -r 2>/dev/null || true
            \\      ;;
            \\  esac
            \\  return $exit_code
            \\}
            \\
            \\binget_reset_path() {
            \\  if [ -n "$BINGET_OG_PATH" ]; then
            \\    export PATH="$BINGET_OG_PATH"
            \\  fi
            \\}
            \\
            \\if [ -z "$BINGET_OG_PATH" ]; then
            \\  export BINGET_OG_PATH="$PATH"
            \\fi
            \\
            \\_binget_hook() {
            \\  local exit_code=$?
            \\  eval "$(command binget shell compute bash)"
            \\  return $exit_code
            \\}
            \\if [[ ";${PROMPT_COMMAND:-};" != *";_binget_hook;"* ]]; then
            \\  PROMPT_COMMAND="_binget_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
            \\fi
            \\
        ) catch {};
    } else if (std.mem.eql(u8, shell_name, "zsh")) {
        stdout.writeAll(
            \\binget() {
            \\  local command_name=$1
            \\  command binget "$@"
            \\  local exit_code=$?
            \\  case "$command_name" in
            \\    install|add|remove|upgrade|uninstall)
            \\      eval "$(command binget shell compute zsh)"
            \\      rehash 2>/dev/null || true
            \\      ;;
            \\  esac
            \\  return $exit_code
            \\}
            \\
            \\binget_reset_path() {
            \\  if [ -n "$BINGET_OG_PATH" ]; then
            \\    export PATH="$BINGET_OG_PATH"
            \\  fi
            \\}
            \\
            \\if [ -z "$BINGET_OG_PATH" ]; then
            \\  export BINGET_OG_PATH="$PATH"
            \\fi
            \\
            \\_binget_hook() {
            \\  eval "$(command binget shell compute zsh)"
            \\}
            \\typeset -a precmd_functions
            \\if [[ ${precmd_functions[(ie)_binget_hook]} -eq ${#precmd_functions} + 1 ]]; then
            \\  precmd_functions+=(_binget_hook)
            \\fi
            \\
        ) catch {};
    } else if (std.mem.eql(u8, shell_name, "fish")) {
        stdout.writeAll(
            \\function binget
            \\  set -l command_name $argv[1]
            \\  command binget $argv
            \\  set -l exit_code $status
            \\  if contains -- $command_name install add remove upgrade uninstall
            \\    command binget shell compute fish | source
            \\  end
            \\  return $exit_code
            \\end
            \\
            \\function binget_reset_path
            \\  if set -q BINGET_OG_PATH
            \\    set -gx PATH $BINGET_OG_PATH
            \\  end
            \\end
            \\
            \\if not set -q BINGET_OG_PATH
            \\  set -gx BINGET_OG_PATH $PATH
            \\end
            \\
            \\function _binget_hook --on-variable PWD --description 'binget env activate'
            \\  command binget shell compute fish | source
            \\end
            \\command binget shell compute fish | source
            \\
        ) catch {};
    } else if (std.mem.eql(u8, shell_name, "sh")) {
        stdout.writeAll(
            \\binget() {
            \\  command_name=$1
            \\  command binget "$@"
            \\  exit_code=$?
            \\  case "$command_name" in
            \\    install|add|remove|upgrade|uninstall)
            \\      eval "$(command binget shell compute sh)"
            \\      hash -r 2>/dev/null || true
            \\      ;;
            \\  esac
            \\  return $exit_code
            \\}
            \\
            \\binget_reset_path() {
            \\  if [ -n "$BINGET_OG_PATH" ]; then
            \\    export PATH="$BINGET_OG_PATH"
            \\  fi
            \\}
            \\
            \\if [ -z "$BINGET_OG_PATH" ]; then
            \\  export BINGET_OG_PATH="$PATH"
            \\fi
            \\
            \\cd() {
            \\  command cd "$@"
            \\  exit_code=$?
            \\  if [ $exit_code -eq 0 ]; then
            \\    eval "$(command binget shell compute sh)"
            \\  fi
            \\  return $exit_code
            \\}
            \\
            \\eval "$(command binget shell compute sh)"
            \\
        ) catch {};
    } else if (std.mem.eql(u8, shell_name, "pwsh") or std.mem.eql(u8, shell_name, "powershell")) {
        stdout.writeAll(
            \\function binget {
            \\  $command_name = $args[0]
            \\  & binget.exe @args
            \\  $exit_code = $LASTEXITCODE
            \\  if ($command_name -in @("install", "add", "remove", "upgrade", "uninstall")) {
            \\    Invoke-Expression (& binget.exe shell compute pwsh | Out-String)
            \\  }
            \\  return $exit_code
            \\}
            \\
            \\function binget_reset_path {
            \\  if ($env:BINGET_OG_PATH) {
            \\    $env:PATH = $env:BINGET_OG_PATH
            \\  }
            \\}
            \\
            \\if (-not $env:BINGET_OG_PATH) {
            \\  $env:BINGET_OG_PATH = $env:PATH
            \\}
            \\
        ) catch {};
    }
}

pub fn computeEnvDiff(allocator: std.mem.Allocator, shell_name: []const u8) !void {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);
    const env_base_dir = try std.fs.path.join(allocator, &.{ share_dir, "env" });
    defer allocator.free(env_base_dir);

    var clean_path = std.ArrayList(u8).empty;
    defer clean_path.deinit(allocator);

    if (env_map.get("PATH")) |current_path| {
        // use proper split by : (assume posix for now)
        var it = std.mem.splitScalar(u8, current_path, ':');
        var first = true;
        while (it.next()) |p| {
            if (std.mem.startsWith(u8, p, env_base_dir)) {
                continue;
            }
            if (!first) {
                try clean_path.append(allocator, ':');
            }
            try clean_path.appendSlice(allocator, p);
            first = false;
        }
    }

    // We update the env_map PATH to the clean one, so evaluate() sees it correctly
    try env_map.put("PATH", clean_path.items);

    const config_path_opt = try findConfig(allocator);
    var config_dir: ?[]const u8 = null;
    if (config_path_opt) |cp| {
        config_dir = std.fs.path.dirname(cp);
    }
    defer if (config_path_opt) |cp| allocator.free(cp);

    const active_dir = env_map.get("BINGET_ACTIVE_DIR");
    if (config_dir) |cd| {
        if (active_dir != null and std.mem.eql(u8, active_dir.?, cd)) {
            return;
        }
    } else {
        if (active_dir == null) {
            return;
        }
    }

    if (env_map.get("BINGET_ADDED_VARS")) |added_vars| {
        var it = std.mem.splitScalar(u8, added_vars, ',');
        while (it.next()) |v| {
            if (v.len > 0) {
                printUnset(allocator, shell_name, v);
            }
        }
    }

    if (config_dir == null) {
        printUnset(allocator, shell_name, "BINGET_ACTIVE_DIR");
        printUnset(allocator, shell_name, "BINGET_ADDED_VARS");
        printExport(allocator, shell_name, "PATH", clean_path.items);
        return;
    }

    if (try loadAndEvaluate(allocator, &env_map)) |var_map| {
        var map = var_map;
        defer {
            var map_it = map.iterator();
            while (map_it.next()) |e| {
                allocator.free(e.key_ptr.*);
                allocator.free(e.value_ptr.*);
            }
            map.deinit();
        }

        var added_vars_str = std.ArrayList(u8).empty;
        defer added_vars_str.deinit(allocator);
        var first = true;

        var it = map.iterator();
        while (it.next()) |entry| {
            printExport(allocator, shell_name, entry.key_ptr.*, entry.value_ptr.*);

            // don't track PATH as an added var to unset, we manage it via clean_path
            if (!std.mem.eql(u8, entry.key_ptr.*, "PATH")) {
                if (!first) try added_vars_str.append(allocator, ',');
                try added_vars_str.appendSlice(allocator, entry.key_ptr.*);
                first = false;
            }
        }

        printExport(allocator, shell_name, "BINGET_ADDED_VARS", added_vars_str.items);
        printExport(allocator, shell_name, "BINGET_ACTIVE_DIR", config_dir.?);
    }
}
