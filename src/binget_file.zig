const std = @import("std");

pub const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

pub const BingetFile = struct {
    allocator: std.mem.Allocator,
    bin_content: []const u8, // We will store the raw block for bin and maybe parse it via YAML later or custom logic
    dotenv_paths: std.ArrayList([]const u8),
    env_vars: std.ArrayList(EnvVar),

    pub fn init(allocator: std.mem.Allocator) BingetFile {
        return .{
            .allocator = allocator,
            .bin_content = "",
            .dotenv_paths = std.ArrayList([]const u8).empty,
            .env_vars = std.ArrayList(EnvVar).empty,
        };
    }

    pub fn deinit(self: *BingetFile) void {
        for (self.dotenv_paths.items) |path| {
            self.allocator.free(path);
        }
        self.dotenv_paths.deinit(self.allocator);

        for (self.env_vars.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        self.env_vars.deinit(self.allocator);
    }
};

const Section = enum {
    none,
    bin,
    dotenv,
    env,
};

pub fn parseBingetFile(allocator: std.mem.Allocator, content: []const u8) !BingetFile {
    var file = BingetFile.init(allocator);
    errdefer file.deinit();

    var current_section: Section = .none;
    var bin_start: ?usize = 0; // default to 0 to capture everything before headers as bin

    var lines = std.mem.splitScalar(u8, content, '\n');

    var in_multiline: bool = false;
    var multiline_key: ?[]const u8 = null;
    errdefer {
        if (multiline_key) |k| allocator.free(k);
    }
    var multiline_val = std.ArrayList(u8).empty;
    defer multiline_val.deinit(allocator);
    var multiline_quote: u8 = 0;

    var offset: usize = 0; // track byte offset for bin_content extraction

    while (lines.next()) |raw_line| {
        const line_len = raw_line.len + 1; // +1 for \n
        defer offset += line_len;

        if (in_multiline) {
            // Find closing quote
            if (std.mem.indexOfScalar(u8, raw_line, multiline_quote)) |idx| {
                try multiline_val.appendSlice(allocator, raw_line[0..idx]);
                try file.env_vars.append(allocator, .{ .key = multiline_key.?, .value = try multiline_val.toOwnedSlice(allocator) });
                multiline_key = null;
                in_multiline = false;
            } else {
                try multiline_val.appendSlice(allocator, raw_line);
                try multiline_val.append(allocator, '\n');
            }
            continue;
        }

        // Strip comments if not inside quotes
        var line = raw_line;
        if (std.mem.indexOfScalar(u8, line, '#')) |idx| {
            // Very naive comment stripping. Will fail if # is inside quotes on a single line
            line = line[0..idx];
        }

        const trimmed = std.mem.trimRight(u8, line, " \r");
        if (trimmed.len == 0) continue;

        // Count leading spaces
        var indent: usize = 0;
        while (indent < trimmed.len and trimmed[indent] == ' ') : (indent += 1) {}

        const content_str = trimmed[indent..];

        if (indent == 0) {
            // Section header
            if (std.mem.startsWith(u8, content_str, "bin")) {
                current_section = .bin;
                bin_start = offset + line_len;
            } else if (std.mem.startsWith(u8, content_str, "dotenv")) {
                current_section = .dotenv;
                if (bin_start) |start| {
                    if (offset > start) {
                        file.bin_content = content[start..offset];
                    }
                    bin_start = null;
                }
            } else if (std.mem.startsWith(u8, content_str, "env")) {
                current_section = .env;
                if (bin_start) |start| {
                    if (offset > start) {
                        file.bin_content = content[start..offset];
                    }
                    bin_start = null;
                }
            }
            continue;
        }

        switch (current_section) {
            .none => {},
            .bin => {
                // Handled via substring extraction at the end or when section changes
            },
            .dotenv => {
                var path = content_str;
                if (std.mem.startsWith(u8, path, "- ")) {
                    path = path[2..];
                }
                path = std.mem.trim(u8, path, " '\"");
                try file.dotenv_paths.append(allocator, try allocator.dupe(u8, path));
            },
            .env => {
                var separator_idx = std.mem.indexOfScalar(u8, content_str, '=');
                if (separator_idx == null) {
                    separator_idx = std.mem.indexOfScalar(u8, content_str, ':');
                }
                if (separator_idx) |idx| {
                    const key = std.mem.trim(u8, content_str[0..idx], " \t");
                    var val = std.mem.trim(u8, content_str[idx + 1 ..], " \t");

                    if (val.len > 0 and (val[0] == '"' or val[0] == '\'' or val[0] == '`')) {
                        const q = val[0];
                        val = val[1..];
                        if (std.mem.lastIndexOfScalar(u8, val, q)) |end_idx| {
                            // Single line quoted
                            try file.env_vars.append(allocator, .{ .key = try allocator.dupe(u8, key), .value = try allocator.dupe(u8, val[0..end_idx]) });
                        } else {
                            // Start multiline
                            in_multiline = true;
                            multiline_key = try allocator.dupe(u8, key);
                            multiline_quote = q;
                            try multiline_val.appendSlice(allocator, val);
                            try multiline_val.append(allocator, '\n');
                        }
                    } else {
                        // Unquoted
                        try file.env_vars.append(allocator, .{ .key = try allocator.dupe(u8, key), .value = try allocator.dupe(u8, val) });
                    }
                }
            },
        }
    }

    if (bin_start) |start| {
        if (content.len > start) {
            file.bin_content = content[start..content.len];
        }
    }

    if (in_multiline) {
        if (multiline_key) |k| {
            try file.env_vars.append(allocator, .{ .key = k, .value = try multiline_val.toOwnedSlice(allocator) });
            multiline_key = null;
        }
    }

    return file;
}

test "parse binget file" {
    const input =
        \\bin:
        \\    github.com/org/repo@v1:
        \\        template: v{version}/{repo}_{platform}_{arch}.tar.gz 
        \\        bin:
        \\             - "first_bin"
        \\             - "second_bin" 
        \\    ripgrep@vwhatever
        \\
        \\# comment
        \\dotenv
        \\     - ./relative/path/.env
        \\     - ./relative/path/.env.user?  # do not throw if not found with question mark
        \\
        \\env
        \\     MY_VAR="test"
        \\     NEXT_VAR="${MY_VAR}"
        \\     DEFAULTED="${DEF:-whatever}"
        \\     SECRET="$(kpv ensure --name 'name' --size 32)"
        \\     MULTILINE="first
        \\next
        \\    "
        \\     SINGLE=''
        \\     BACKTICK=``
    ;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bf = try parseBingetFile(allocator, input);
    defer bf.deinit();

    const get_env = struct {
        fn get(list: std.ArrayList(EnvVar), key: []const u8) ?[]const u8 {
            for (list.items) |item| {
                if (std.mem.eql(u8, item.key, key)) return item.value;
            }
            return null;
        }
    }.get;

    try std.testing.expectEqualStrings("test", get_env(bf.env_vars, "MY_VAR").?);
    try std.testing.expectEqualStrings("${MY_VAR}", get_env(bf.env_vars, "NEXT_VAR").?);
    try std.testing.expectEqualStrings("${DEF:-whatever}", get_env(bf.env_vars, "DEFAULTED").?);
    try std.testing.expectEqualStrings("first\nnext\n    ", get_env(bf.env_vars, "MULTILINE").?);
    try std.testing.expectEqualStrings("", get_env(bf.env_vars, "SINGLE").?);
    try std.testing.expectEqualStrings("", get_env(bf.env_vars, "BACKTICK").?);

    try std.testing.expectEqual(@as(usize, 2), bf.dotenv_paths.items.len);
    try std.testing.expectEqualStrings("./relative/path/.env", bf.dotenv_paths.items[0]);
    try std.testing.expectEqualStrings("./relative/path/.env.user?", bf.dotenv_paths.items[1]);
}
