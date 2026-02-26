const std = @import("std");
const db = @import("db.zig");
pub fn upgradePackage(allocator: std.mem.Allocator, db_conn: db.Database, target: []const u8, global: bool) !void { _ = allocator; _ = db_conn; _ = target; _ = global; }
