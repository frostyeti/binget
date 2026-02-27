const std = @import("std");
const core = @import("../core.zig");
const db = @import("../db.zig");
const install_cmd = @import("../install_cmd.zig");

// Import specific runtimes
const zig = @import("zig.zig");
const go = @import("go.zig");
const node = @import("node.zig");
const rust = @import("rust.zig");
const dotnet = @import("dotnet.zig");
const deno = @import("deno.zig");
const uv = @import("uv.zig");
const python = @import("python.zig");
const ruby = @import("ruby.zig");
const java = @import("java.zig");
const php = @import("php.zig");
const perl = @import("perl.zig");
const erlang = @import("erlang.zig");
const elixir = @import("elixir.zig");
const swift = @import("swift.zig");
const kotlin = @import("kotlin.zig");
const clojure = @import("clojure.zig");
const odin = @import("odin.zig");

pub fn isBuiltin(id: []const u8) bool {
    if (std.mem.eql(u8, id, "zig")) return true;
    if (std.mem.eql(u8, id, "go")) return true;
    if (std.mem.eql(u8, id, "node")) return true;
    if (std.mem.eql(u8, id, "rust")) return true;
    if (std.mem.eql(u8, id, "dotnet")) return true;
    if (std.mem.eql(u8, id, "deno")) return true;
    if (std.mem.eql(u8, id, "uv")) return true;
    if (std.mem.eql(u8, id, "python")) return true;
    if (std.mem.eql(u8, id, "ruby")) return true;
    if (std.mem.eql(u8, id, "java")) return true;
    if (std.mem.eql(u8, id, "php")) return true;
    if (std.mem.eql(u8, id, "perl")) return true;
    if (std.mem.eql(u8, id, "erlang")) return true;
    if (std.mem.eql(u8, id, "elixir")) return true;
    if (std.mem.eql(u8, id, "swift")) return true;
    if (std.mem.eql(u8, id, "kotlin")) return true;
    if (std.mem.eql(u8, id, "clojure")) return true;
    if (std.mem.eql(u8, id, "odin")) return true;
    return false;
}

pub fn install(allocator: std.mem.Allocator, db_conn: db.Database, id: []const u8, version_opt: ?[]const u8, mode: install_cmd.InstallMode) !void {
    if (std.mem.eql(u8, id, "zig")) {
        return zig.install(allocator, db_conn, version_opt, mode);
    }
    if (std.mem.eql(u8, id, "go")) {
        return go.install(allocator, db_conn, version_opt, mode);
    }
    if (std.mem.eql(u8, id, "node")) {
        return node.install(allocator, db_conn, version_opt, mode);
    }
    if (std.mem.eql(u8, id, "rust")) {
        return rust.install(allocator, db_conn, version_opt, mode);
    }
    if (std.mem.eql(u8, id, "dotnet")) {
        return dotnet.install(allocator, db_conn, version_opt, mode);
    }
    if (std.mem.eql(u8, id, "deno")) {
        return deno.install(allocator, db_conn, version_opt, mode);
    }
    if (std.mem.eql(u8, id, "uv")) {
        return uv.install(allocator, db_conn, version_opt, mode);
    }
    if (std.mem.eql(u8, id, "python")) {
        return python.install(allocator, db_conn, version_opt, mode);
    }
    if (std.mem.eql(u8, id, "ruby")) {
        return ruby.install(allocator, db_conn, version_opt, mode);
    }
    if (std.mem.eql(u8, id, "java")) {
        return java.install(allocator, db_conn, version_opt, mode);
    }
    if (std.mem.eql(u8, id, "php")) {
        return php.install(allocator, db_conn, version_opt, mode);
    }
    if (std.mem.eql(u8, id, "perl")) {
        return perl.install(allocator, db_conn, version_opt, mode);
    }
    if (std.mem.eql(u8, id, "erlang")) {
        return erlang.install(allocator, db_conn, version_opt, mode);
    }
    if (std.mem.eql(u8, id, "elixir")) {
        return elixir.install(allocator, db_conn, version_opt, mode);
    }
    if (std.mem.eql(u8, id, "swift")) {
        return swift.install(allocator, db_conn, version_opt, mode);
    }
    if (std.mem.eql(u8, id, "kotlin")) {
        return kotlin.install(allocator, db_conn, version_opt, mode);
    }
    if (std.mem.eql(u8, id, "clojure")) {
        return clojure.install(allocator, db_conn, version_opt, mode);
    }
    if (std.mem.eql(u8, id, "odin")) {
        return odin.install(allocator, db_conn, version_opt, mode);
    }
    return error.UnknownBuiltin;
}
