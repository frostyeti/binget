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
    return error.UnknownBuiltin;
}
