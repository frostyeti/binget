const std = @import("std");
const core = @import("../core.zig");
const db = @import("../db.zig");
const install_cmd = @import("../install_cmd.zig");

pub fn install(allocator: std.mem.Allocator, db_conn: db.Database, version_opt: ?[]const u8, mode: install_cmd.InstallMode) !void {
    _ = allocator;
    _ = db_conn;
    _ = version_opt;
    _ = mode;
    std.debug.print("Resolving builtin runtime 'perl'...\n", .{});
    std.debug.print("Installation logic for 'perl' is not yet implemented.\n", .{});
    return error.NotImplemented;
}
