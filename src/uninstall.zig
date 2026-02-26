const std = @import("std");
const db = @import("db.zig");
pub fn uninstallPackage(allocator: std.mem.Allocator, db_conn: db.Database, target: []const u8) !void { _ = allocator; _ = db_conn; _ = target; }
