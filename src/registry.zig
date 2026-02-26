const std = @import("std");

pub const Cve = struct {
    id: []const u8,
    score: f64,
    description: []const u8,
};

pub const VersionInfo = struct {
    version: []const u8,
    status: []const u8,
    cves: ?[]Cve = null,
};

pub const VersionsFile = struct {
    latest: []const u8,
    versions: []VersionInfo,
};

fn getRegistryUrl(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "BINGET_REGISTRY_URL")) |url| {
        return url;
    } else |err| {
        switch (err) {
            error.EnvironmentVariableNotFound => return try allocator.dupe(u8, "https://raw.githubusercontent.com/frostyeti/binget-pkgs/dev"),
            else => return err,
        }
    }
}

fn getFirstChar(id: []const u8) u8 {
    return std.ascii.toLower(id[0]);
}

pub fn fetchVersions(allocator: std.mem.Allocator, id: []const u8) !VersionsFile {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const char = getFirstChar(id);
    const reg_url = try getRegistryUrl(allocator);
    defer allocator.free(reg_url);
    const url = try std.fmt.allocPrint(allocator, "{s}/{c}/{s}/versions.json", .{ reg_url, char, id });
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();
    var redirect_buf: [8192]u8 = undefined;
    var res = try req.receiveHead(&redirect_buf);

    if (res.head.status != .ok) {
        return error.PackageNotFound;
    }

    var transfer_buf: [8192]u8 = undefined;
    var decompress_buf: [65536]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const limit: std.io.Limit = @enumFromInt(1024 * 1024);
    const body = try res.readerDecompressing(&transfer_buf, &decompress, &decompress_buf).allocRemaining(allocator, limit);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const latest = root.get("latest").?.string;

    const versions_arr = root.get("versions").?.array;
    var parsed_versions = try allocator.alloc(VersionInfo, versions_arr.items.len);

    for (versions_arr.items, 0..) |v_val, i| {
        const v_obj = v_val.object;

        var cves: ?[]Cve = null;
        if (v_obj.get("cves")) |cves_val| {
            const c_arr = cves_val.array;
            cves = try allocator.alloc(Cve, c_arr.items.len);
            for (c_arr.items, 0..) |c_item, j| {
                const c_obj = c_item.object;

                // score can be int or float in JSON
                var score: f64 = 0;
                if (c_obj.get("score")) |sv| {
                    switch (sv) {
                        .float => |f| score = f,
                        .integer => |int| score = @floatFromInt(int),
                        else => {},
                    }
                }

                cves.?[j] = Cve{
                    .id = try allocator.dupe(u8, c_obj.get("id").?.string),
                    .score = score,
                    .description = try allocator.dupe(u8, c_obj.get("description").?.string),
                };
            }
        }

        parsed_versions[i] = VersionInfo{
            .version = try allocator.dupe(u8, v_obj.get("version").?.string),
            .status = try allocator.dupe(u8, v_obj.get("status").?.string),
            .cves = cves,
        };
    }

    return VersionsFile{
        .latest = try allocator.dupe(u8, latest),
        .versions = parsed_versions,
    };
}

pub fn freeVersions(allocator: std.mem.Allocator, vf: VersionsFile) void {
    allocator.free(vf.latest);
    for (vf.versions) |v| {
        allocator.free(v.version);
        allocator.free(v.status);
        if (v.cves) |cves| {
            for (cves) |c| {
                allocator.free(c.id);
                allocator.free(c.description);
            }
            allocator.free(cves);
        }
    }
    allocator.free(vf.versions);
}

pub const Manifest = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    author: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    license: ?[]const u8 = null,
    description: ?[]const u8 = null,
    platforms: [][]const u8,
};

// ... platform manifest parsing to follow

pub const RegistryKey = struct {
    path: []const u8,
    name: ?[]const u8 = null,
    type: ?[]const u8 = null,
    value: ?[]const u8 = null,
    ensure_exists: ?bool = null,
    remove: ?bool = null,
};

pub const Shortcut = struct {
    name: []const u8,
    target: []const u8,
    location: []const u8,
    icon: ?[]const u8 = null,
};

pub const Link = struct {
    target: []const u8,
    link: []const u8,
    type: []const u8,
};

pub const InstallModeConfig = struct {
    type: []const u8,
    format: ?[]const u8 = null,
    url: ?[]const u8 = null,
    checksum: ?[]const u8 = null,
    extract_dir: ?[]const u8 = null,
    bin: ?[][]const u8 = null,
    package: ?[]const u8 = null, // for apt, winget, etc
    registry_keys: ?[]RegistryKey = null,
    shortcuts: ?[]Shortcut = null,
    links: ?[]Link = null,
    build_engine: ?[]const u8 = null,
    build_args: ?[][]const u8 = null,
    silent_args: ?[][]const u8 = null,
};

pub const PlatformManifest = struct {
    install_modes: struct {
        shim: ?InstallModeConfig = null,
        user: ?InstallModeConfig = null,
        global: ?InstallModeConfig = null,
    },
};

fn parseInstallModeConfig(allocator: std.mem.Allocator, mode_val: std.json.Value) !InstallModeConfig {
    const obj = mode_val.object;

    var config = InstallModeConfig{
        .type = try allocator.dupe(u8, obj.get("type").?.string),
    };

    if (obj.get("format")) |v| config.format = try allocator.dupe(u8, v.string);
    if (obj.get("url")) |v| config.url = try allocator.dupe(u8, v.string);
    if (obj.get("checksum")) |v| config.checksum = try allocator.dupe(u8, v.string);
    if (obj.get("extract_dir")) |v| config.extract_dir = try allocator.dupe(u8, v.string);
    if (obj.get("package")) |v| config.package = try allocator.dupe(u8, v.string);

    if (obj.get("bin")) |v| {
        const bin_arr = v.array;
        var bins = try allocator.alloc([]const u8, bin_arr.items.len);
        for (bin_arr.items, 0..) |bin_item, i| {
            bins[i] = try allocator.dupe(u8, bin_item.string);
        }
        config.bin = bins;
    }

    if (obj.get("registry_keys")) |v| {
        const arr = v.array;
        var keys = try allocator.alloc(RegistryKey, arr.items.len);
        for (arr.items, 0..) |item, i| {
            const k_obj = item.object;
            keys[i] = RegistryKey{
                .path = try allocator.dupe(u8, k_obj.get("path").?.string),
                .name = if (k_obj.get("name")) |n| try allocator.dupe(u8, n.string) else null,
                .type = if (k_obj.get("type")) |t| try allocator.dupe(u8, t.string) else null,
                .value = if (k_obj.get("value")) |val| try allocator.dupe(u8, val.string) else null,
                .ensure_exists = if (k_obj.get("ensure_exists")) |b| b.bool else null,
                .remove = if (k_obj.get("remove")) |b| b.bool else null,
            };
        }
        config.registry_keys = keys;
    }

    if (obj.get("shortcuts")) |v| {
        const arr = v.array;
        var shortcuts = try allocator.alloc(Shortcut, arr.items.len);
        for (arr.items, 0..) |item, i| {
            const s_obj = item.object;
            shortcuts[i] = Shortcut{
                .name = try allocator.dupe(u8, s_obj.get("name").?.string),
                .target = try allocator.dupe(u8, s_obj.get("target").?.string),
                .location = try allocator.dupe(u8, s_obj.get("location").?.string),
                .icon = if (s_obj.get("icon")) |ic| try allocator.dupe(u8, ic.string) else null,
            };
        }
        config.shortcuts = shortcuts;
    }

    if (obj.get("links")) |v| {
        const arr = v.array;
        var links = try allocator.alloc(Link, arr.items.len);
        for (arr.items, 0..) |item, i| {
            const l_obj = item.object;
            links[i] = Link{
                .target = try allocator.dupe(u8, l_obj.get("target").?.string),
                .link = try allocator.dupe(u8, l_obj.get("link").?.string),
                .type = try allocator.dupe(u8, l_obj.get("type").?.string),
            };
        }
        config.links = links;
    }

    if (obj.get("build_engine")) |v| config.build_engine = try allocator.dupe(u8, v.string);
    if (obj.get("build_args")) |v| {
        const args_arr = v.array;
        var args = try allocator.alloc([]const u8, args_arr.items.len);
        for (args_arr.items, 0..) |arg_item, i| {
            args[i] = try allocator.dupe(u8, arg_item.string);
        }
        config.build_args = args;
    }

    if (obj.get("silent_args")) |v| {
        const args_arr = v.array;
        var args = try allocator.alloc([]const u8, args_arr.items.len);
        for (args_arr.items, 0..) |arg_item, i| {
            args[i] = try allocator.dupe(u8, arg_item.string);
        }
        config.silent_args = args;
    }

    return config;
}

pub fn fetchPlatformManifest(allocator: std.mem.Allocator, id: []const u8, version: []const u8, platform: []const u8) !PlatformManifest {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const char = getFirstChar(id);
    const reg_url = try getRegistryUrl(allocator);
    defer allocator.free(reg_url);
    const url = try std.fmt.allocPrint(allocator, "{s}/{c}/{s}/{s}/manifest.{s}.json", .{ reg_url, char, id, version, platform });
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);
    var server_header_buffer: [8192]u8 = undefined;

    var req = try client.request(.GET, uri, .{});
    defer req.deinit();

    try req.sendBodiless();
    var res = try req.receiveHead(&server_header_buffer);

    if (res.head.status != .ok) {
        return error.PlatformManifestNotFound;
    }

    var transfer_buf: [4096]u8 = undefined;
    var decompress_buf: [65536]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const limit: std.io.Limit = @enumFromInt(1024 * 1024);
    const body = try res.readerDecompressing(&transfer_buf, &decompress, &decompress_buf).allocRemaining(allocator, limit);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const modes_obj = root.get("install_modes").?.object;

    var manifest = PlatformManifest{ .install_modes = .{} };

    if (modes_obj.get("shim")) |v| manifest.install_modes.shim = try parseInstallModeConfig(allocator, v);
    if (modes_obj.get("user")) |v| manifest.install_modes.user = try parseInstallModeConfig(allocator, v);
    if (modes_obj.get("global")) |v| manifest.install_modes.global = try parseInstallModeConfig(allocator, v);

    return manifest;
}

pub fn freePlatformManifest(allocator: std.mem.Allocator, pm: PlatformManifest) void {
    const modes = pm.install_modes;
    if (modes.shim) |m| freeInstallModeConfig(allocator, m);
    if (modes.user) |m| freeInstallModeConfig(allocator, m);
    if (modes.global) |m| freeInstallModeConfig(allocator, m);
}

fn freeInstallModeConfig(allocator: std.mem.Allocator, m: InstallModeConfig) void {
    allocator.free(m.type);
    if (m.format) |v| allocator.free(v);
    if (m.url) |v| allocator.free(v);
    if (m.checksum) |v| allocator.free(v);
    if (m.extract_dir) |v| allocator.free(v);
    if (m.package) |v| allocator.free(v);
    if (m.bin) |bins| {
        for (bins) |b| allocator.free(b);
        allocator.free(bins);
    }
    if (m.registry_keys) |keys| {
        for (keys) |k| {
            allocator.free(k.path);
            if (k.name) |n| allocator.free(n);
            if (k.type) |t| allocator.free(t);
            if (k.value) |v| allocator.free(v);
        }
        allocator.free(keys);
    }
    if (m.shortcuts) |shortcuts| {
        for (shortcuts) |s| {
            allocator.free(s.name);
            allocator.free(s.target);
            allocator.free(s.location);
            if (s.icon) |ic| allocator.free(ic);
        }
        allocator.free(shortcuts);
    }
    if (m.links) |links| {
        for (links) |l| {
            allocator.free(l.target);
            allocator.free(l.link);
            allocator.free(l.type);
        }
        allocator.free(links);
    }
    if (m.build_engine) |v| allocator.free(v);
    if (m.build_args) |args| {
        for (args) |a| allocator.free(a);
        allocator.free(args);
    }
    if (m.silent_args) |args| {
        for (args) |a| allocator.free(a);
        allocator.free(args);
    }
}
