const std = @import("std");
const core = @import("core.zig");
const registry = @import("registry.zig");
const github = @import("github.zig");
const archive = @import("archive.zig");

const fetch_help =
    \\Download an asset for a package, github repository, or URL.
    \\
    \\Usage:
    \\  binget fetch <name>[-<version>] [-o <output_path>] [--format <hint>]
    \\
    \\Examples:
    \\  binget fetch curl
    \\  binget fetch github.com/stedolan/jq
    \\  binget fetch https://example.com/manifest.json --format deb
    \\
    \\Options:
    \\  -o, --out        Output path for the downloaded asset
    \\  --format         Hint for the preferred format (e.g. deb, rpm, zip, tar)
    \\  -h, --help       Show this help message and exit
    \\
;

fn fetchToMemory(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5),
    });
    defer req.deinit();

    try req.sendBodiless();
    var redirect_buf: [8192]u8 = undefined;
    var res = try req.receiveHead(&redirect_buf);

    if (res.head.status != .ok) {
        return error.HttpFailed;
    }

    var transfer_buf: [8192]u8 = undefined;
    var decompress_buf: [65536]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const limit: std.io.Limit = @enumFromInt(10 * 1024 * 1024);
    return try res.readerDecompressing(&transfer_buf, &decompress, &decompress_buf).allocRemaining(allocator, limit);
}

const FormatScore = struct {
    mode_name: []const u8,
    url: []const u8,
    score: i32,
};

fn scoreFormat(format: ?[]const u8, format_hint: ?[]const u8) i32 {
    if (format == null) return 0;
    const f = format.?;

    // Exact match with hint is highest priority
    if (format_hint) |hint| {
        if (std.ascii.indexOfIgnoreCase(f, hint) != null) {
            return 100;
        }
    }

    // Preference order: archives > nupkg > deb/rpm > msi
    if (std.ascii.indexOfIgnoreCase(f, "tar") != null) return 50;
    if (std.ascii.indexOfIgnoreCase(f, "zip") != null) return 40;
    if (std.ascii.indexOfIgnoreCase(f, "nupkg") != null) return 30;

    const builtin = @import("builtin");
    if (builtin.os.tag == .linux) {
        if (std.ascii.indexOfIgnoreCase(f, "deb") != null) return 25;
        if (std.ascii.indexOfIgnoreCase(f, "rpm") != null) return 20;
    }

    return 10;
}

fn extractUrlFromPlatformManifest(allocator: std.mem.Allocator, platform_manifest_url: []const u8, format_hint: ?[]const u8) ![]const u8 {
    const content = fetchToMemory(allocator, platform_manifest_url) catch return try allocator.dupe(u8, platform_manifest_url);
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return try allocator.dupe(u8, platform_manifest_url);
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return try allocator.dupe(u8, platform_manifest_url);

    if (root.object.get("install_modes")) |modes_val| {
        if (modes_val == .object) {
            var best_score: i32 = -1;
            var best_url: ?[]const u8 = null;

            const modes = modes_val.object;
            var it = modes.iterator();
            while (it.next()) |entry| {
                const mode_name = entry.key_ptr.*;
                const m_val = entry.value_ptr.*;
                if (m_val == .object) {
                    if (m_val.object.get("url")) |u_val| {
                        if (u_val == .string) {
                            var fmt: ?[]const u8 = null;
                            if (m_val.object.get("format")) |f_val| {
                                if (f_val == .string) fmt = f_val.string;
                            }

                            var score = scoreFormat(fmt, format_hint);
                            if (std.mem.eql(u8, mode_name, "user")) {
                                score += 5;
                            } else if (std.mem.eql(u8, mode_name, "global")) {
                                score += 3;
                            }

                            if (score > best_score) {
                                best_score = score;
                                best_url = u_val.string;
                            }
                        }
                    }
                }
            }

            if (best_url) |u| {
                std.debug.print("Resolved artifact URL from platform manifest.\n", .{});
                return try allocator.dupe(u8, u);
            }
        }
    }
    return try allocator.dupe(u8, platform_manifest_url);
}

fn resolveManifestUrl(allocator: std.mem.Allocator, initial_url: []const u8, format_hint: ?[]const u8) ![]const u8 {
    const is_json = std.ascii.endsWithIgnoreCase(initial_url, ".json");
    const is_yaml = std.ascii.endsWithIgnoreCase(initial_url, ".yaml") or std.ascii.endsWithIgnoreCase(initial_url, ".yml");

    if (!is_json and !is_yaml) {
        return try allocator.dupe(u8, initial_url);
    }

    const content = fetchToMemory(allocator, initial_url) catch return try allocator.dupe(u8, initial_url);
    defer allocator.free(content);

    if (is_json) {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
            return try allocator.dupe(u8, initial_url);
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return try allocator.dupe(u8, initial_url);

        // 1. Is it a Platform Manifest? (has install_modes at root)
        if (root.object.get("install_modes") != null) {
            // Re-use logic since we already fetched it
            var best_score: i32 = -1;
            var best_url: ?[]const u8 = null;
            const modes = root.object.get("install_modes").?.object;
            var it = modes.iterator();
            while (it.next()) |entry| {
                const mode_name = entry.key_ptr.*;
                const m_val = entry.value_ptr.*;
                if (m_val == .object) {
                    if (m_val.object.get("url")) |u_val| {
                        if (u_val == .string) {
                            var fmt: ?[]const u8 = null;
                            if (m_val.object.get("format")) |f_val| {
                                if (f_val == .string) fmt = f_val.string;
                            }
                            var score = scoreFormat(fmt, format_hint);
                            if (std.mem.eql(u8, mode_name, "user")) {
                                score += 5;
                            } else if (std.mem.eql(u8, mode_name, "global")) {
                                score += 3;
                            }

                            if (score > best_score) {
                                best_score = score;
                                best_url = u_val.string;
                            }
                        }
                    }
                }
            }
            if (best_url) |u| {
                std.debug.print("Resolved artifact URL from root platform manifest.\n", .{});
                return try allocator.dupe(u8, u);
            }
        }

        // 2. Is it a multi-version manifest? (has 'versions' array)
        if (root.object.get("versions")) |versions_val| {
            if (versions_val == .array and versions_val.array.items.len > 0) {
                // Get latest version
                const latest_v = versions_val.array.items[0];
                if (latest_v == .object) {
                    if (latest_v.object.get("platforms")) |plats_val| {
                        if (plats_val == .object) {
                            const builtin = @import("builtin");
                            const os_tag = @tagName(builtin.os.tag);
                            const arch_tag = @tagName(builtin.cpu.arch);

                            // Try macos-x86_64 format
                            const platform_id_dash = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ os_tag, arch_tag });
                            defer allocator.free(platform_id_dash);

                            // Try macos.amd64 format
                            const os_tag_mapped = if (builtin.os.tag == .macos) "darwin" else os_tag;
                            const arch_tag_mapped = if (builtin.cpu.arch == .x86_64) "amd64" else if (builtin.cpu.arch == .aarch64) "aarch64" else arch_tag;
                            const platform_id_dot = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ os_tag_mapped, arch_tag_mapped });
                            defer allocator.free(platform_id_dot);

                            var plat_obj: ?std.json.ObjectMap = null;
                            if (plats_val.object.get(platform_id_dash)) |p| {
                                if (p == .object) plat_obj = p.object;
                            } else if (plats_val.object.get(platform_id_dot)) |p| {
                                if (p == .object) plat_obj = p.object;
                            }

                            if (plat_obj) |p_obj| {
                                if (p_obj.get("install_modes")) |modes_val| {
                                    if (modes_val == .object) {
                                        var best_score: i32 = -1;
                                        var best_url: ?[]const u8 = null;
                                        const modes = modes_val.object;
                                        var it = modes.iterator();
                                        while (it.next()) |entry| {
                                            const mode_name = entry.key_ptr.*;
                                            const m_val = entry.value_ptr.*;
                                            if (m_val == .object) {
                                                if (m_val.object.get("url")) |u_val| {
                                                    if (u_val == .string) {
                                                        var fmt: ?[]const u8 = null;
                                                        if (m_val.object.get("format")) |f_val| {
                                                            if (f_val == .string) fmt = f_val.string;
                                                        }
                                                        var score = scoreFormat(fmt, format_hint);
                                                        if (std.mem.eql(u8, mode_name, "user")) {
                                                            score += 5;
                                                        } else if (std.mem.eql(u8, mode_name, "global")) {
                                                            score += 3;
                                                        }

                                                        if (score > best_score) {
                                                            best_score = score;
                                                            best_url = u_val.string;
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        if (best_url) |u| {
                                            std.debug.print("Resolved artifact URL from versions > platforms manifest.\n", .{});
                                            return try allocator.dupe(u8, u);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // 3. Is it a Package Manifest with platforms array? (old style)
        if (root.object.get("platforms")) |plats_val| {
            if (plats_val == .array) {
                const builtin = @import("builtin");
                const os_tag = @tagName(builtin.os.tag);
                const os_tag_mapped = if (builtin.os.tag == .macos) "darwin" else os_tag;
                const arch_tag = @tagName(builtin.cpu.arch);
                const arch_tag_mapped = if (builtin.cpu.arch == .x86_64) "amd64" else if (builtin.cpu.arch == .aarch64) "aarch64" else arch_tag;

                const platform_id_dot = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ os_tag_mapped, arch_tag_mapped });
                defer allocator.free(platform_id_dot);
                const platform_id_dash = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ os_tag, arch_tag });
                defer allocator.free(platform_id_dash);

                var found_plat: ?[]const u8 = null;
                for (plats_val.array.items) |p_val| {
                    if (p_val == .string) {
                        if (std.mem.eql(u8, p_val.string, platform_id_dot)) {
                            found_plat = platform_id_dot;
                            break;
                        } else if (std.mem.eql(u8, p_val.string, platform_id_dash)) {
                            found_plat = platform_id_dash;
                            break;
                        }
                    }
                }

                if (found_plat) |pid| {
                    var it = std.mem.splitBackwardsScalar(u8, initial_url, '/');
                    _ = it.next(); // skip manifest.json
                    const base = initial_url[0 .. it.index orelse return try allocator.dupe(u8, initial_url)];

                    const plat_url = try std.fmt.allocPrint(allocator, "{s}/manifest.{s}.json", .{ base, pid });
                    defer allocator.free(plat_url);

                    std.debug.print("Resolved package manifest. Fetching platform manifest: {s}\n", .{plat_url});
                    return try extractUrlFromPlatformManifest(allocator, plat_url, format_hint);
                }
            }
        }
    } else if (is_yaml) {
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (std.mem.startsWith(u8, trimmed, "url:")) {
                var parts = std.mem.splitScalar(u8, trimmed, ':');
                _ = parts.next(); // url
                var url_val = parts.rest();
                url_val = std.mem.trim(u8, url_val, " \"\'\r\t");
                if (std.mem.startsWith(u8, url_val, "http")) {
                    std.debug.print("Resolved artifact URL from yaml.\n", .{});
                    return try allocator.dupe(u8, url_val);
                }
            }
        }
    }

    return try allocator.dupe(u8, initial_url);
}

pub fn parseAndRun(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    if (args.len < 3 or std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help")) {
        std.debug.print("{s}", .{fetch_help});
        return;
    }

    var target: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var format_hint: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i < args.len) {
                out_path = args[i];
            } else {
                std.debug.print("Error: -o requires a path\n", .{});
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i < args.len) {
                format_hint = args[i];
            } else {
                std.debug.print("Error: --format requires a hint\n", .{});
                return error.InvalidArgument;
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return error.InvalidArgument;
        } else {
            target = arg;
        }
        i += 1;
    }

    if (target == null) {
        std.debug.print("Error: Target is required\n", .{});
        std.debug.print("{s}", .{fetch_help});
        return error.InvalidArgument;
    }

    const t = target.?;
    const is_github_prefix = std.mem.startsWith(u8, t, "github.com/");
    const is_http_prefix = std.mem.startsWith(u8, t, "http://") or std.mem.startsWith(u8, t, "https://");
    var parts = std.mem.splitScalar(u8, t, '@');
    const name_part = parts.next().?;
    const version_opt = parts.next();

    const has_slash = std.mem.indexOfScalar(u8, name_part, '/') != null;

    var url: []const u8 = undefined;

    if (is_http_prefix) {
        url = try resolveManifestUrl(allocator, t, format_hint);
    } else if (is_github_prefix or has_slash) {
        var repo_path = name_part;
        if (is_github_prefix) {
            repo_path = name_part["github.com/".len..];
        }
        var repo_parts = std.mem.splitScalar(u8, repo_path, '/');
        const owner = repo_parts.next() orelse return error.InvalidTarget;
        const repo = repo_parts.next() orelse return error.InvalidTarget;

        var release: github.Release = undefined;
        if (version_opt) |ver| {
            release = try github.fetchReleaseByTag(allocator, owner, repo, ver);
        } else {
            release = try github.fetchLatestRelease(allocator, owner, repo);
        }
        defer github.freeRelease(allocator, release);

        const u = core.guessAsset(release.assets) orelse {
            std.debug.print("Could not find a suitable asset for this OS/Arch.\n", .{});
            return error.NoAssetFound;
        };
        url = try allocator.dupe(u8, u);
    } else {
        const id = name_part;

        const vf = registry.fetchVersions(allocator, id) catch |err| {
            std.debug.print("Error: Package '{s}' not found in registry ({}).\n", .{ id, err });
            return err;
        };
        defer registry.freeVersions(allocator, vf);

        var version_to_install = vf.latest;
        if (version_opt) |ver| {
            version_to_install = ver;
        }

        const builtin = @import("builtin");
        const os_tag = @tagName(builtin.os.tag);
        const arch_tag = @tagName(builtin.cpu.arch);

        const platform_id = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ os_tag, arch_tag });
        defer allocator.free(platform_id);

        const manifest = registry.fetchPlatformManifest(allocator, id, version_to_install, platform_id) catch |err| {
            std.debug.print("Error: Platform {s} is not supported for {s}@{s} ({}).\n", .{ platform_id, id, version_to_install, err });
            return err;
        };
        defer registry.freePlatformManifest(allocator, manifest);

        // Find best mode URL considering format_hint
        var best_score: i32 = -1;
        var best_url: ?[]const u8 = null;

        const modes = manifest.install_modes;
        if (modes.user) |m| {
            if (m.url) |u| {
                const score = scoreFormat(m.format, format_hint) + 5;
                if (score > best_score) {
                    best_score = score;
                    best_url = u;
                }
            }
        }
        if (modes.global) |m| {
            if (m.url) |u| {
                const score = scoreFormat(m.format, format_hint) + 3;
                if (score > best_score) {
                    best_score = score;
                    best_url = u;
                }
            }
        }
        if (modes.shim) |m| {
            if (m.url) |u| {
                const score = scoreFormat(m.format, format_hint);
                if (score > best_score) {
                    best_score = score;
                    best_url = u;
                }
            }
        }

        if (best_url == null) {
            std.debug.print("Error: No URL found in manifest for {s}\n", .{id});
            return error.NoAssetFound;
        }
        url = try allocator.dupe(u8, best_url.?);
    }

    defer allocator.free(url);

    var final_out: []const u8 = undefined;
    if (out_path) |p| {
        final_out = try allocator.dupe(u8, p);
    } else {
        // extract filename from URL
        var it = std.mem.splitBackwardsScalar(u8, url, '/');
        const filename = it.next() orelse "downloaded_asset";
        const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(cwd_path);

        // If query parameters exist in the url filename part, strip them out
        var file_part_it = std.mem.splitScalar(u8, filename, '?');
        const clean_filename = file_part_it.next() orelse filename;

        final_out = try std.fs.path.join(allocator, &.{ cwd_path, clean_filename });
    }
    defer allocator.free(final_out);

    std.debug.print("Downloading: {s}\n", .{url});
    std.debug.print("Saving to: {s}\n", .{final_out});

    try archive.downloadFile(allocator, url, final_out);
    std.debug.print("Successfully fetched {s}\n", .{final_out});
}
