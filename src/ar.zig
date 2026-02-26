const std = @import("std");

/// Parses a very simple standard `ar` archive (like a .deb file) and extracts
/// a specific file by prefix (e.g., "data.tar").
pub fn extractArMemberByPrefix(
    archive_path: []const u8,
    prefix: []const u8,
    out_path: []const u8,
) !bool {
    var file = try std.fs.cwd().openFile(archive_path, .{});
    defer file.close();

    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(&read_buf);

    // Check magic signature "!<arch>\n"
    var magic: [8]u8 = undefined;
    try reader.interface.readSliceAll(&magic);
    if (!std.mem.eql(u8, &magic, "!<arch>\n")) {
        return error.NotAnArArchive;
    }

    // Read headers
    while (true) {
        var header: [60]u8 = undefined;
        const bytes_read = try reader.interface.readSliceShort(&header);
        if (bytes_read == 0) break; // EOF
        if (bytes_read != 60) return error.MalformedArHeader;

        // The header format:
        // 0-15: File name
        // 16-27: Timestamp
        // 28-33: Owner ID
        // 34-39: Group ID
        // 40-47: File mode
        // 48-57: File size in bytes (ASCII decimal)
        // 58-59: End of header (`\x60\x0A` or "`\n")

        if (header[58] != '`' or header[59] != '\n') {
            return error.MalformedArHeader;
        }

        const name_raw = std.mem.trimRight(u8, header[0..16], " /");
        const size_raw = std.mem.trimRight(u8, header[48..58], " ");
        const size = try std.fmt.parseInt(u64, size_raw, 10);

        if (std.mem.startsWith(u8, name_raw, prefix)) {
            // Found the member we want! Extract it to out_path.
            var out_file = try std.fs.cwd().createFile(out_path, .{});
            defer out_file.close();

            var buffer: [8192]u8 = undefined;
            var remaining = size;
            while (remaining > 0) {
                const to_read = @min(buffer.len, remaining);
                const r = try reader.interface.readSliceShort(buffer[0..to_read]);
                if (r == 0) return error.UnexpectedEofInArMember;
                try out_file.writeAll(buffer[0..r]);
                remaining -= r;
            }
            return true;
        } else {
            // Skip this member. Ar members are padded to an even byte boundary.
            var skip = size;
            if (size % 2 != 0) skip += 1;
            try reader.interface.discardAll64(skip);
        }
    }

    return false; // Member not found
}
