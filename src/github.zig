const std = @import("std");

pub const Release = struct {
    tag_name: []const u8,
    assets: []Asset,

    pub const Asset = struct {
        name: []const u8,
        browser_download_url: []const u8,
    };
};

pub fn fetchLatestRelease(allocator: std.mem.Allocator, owner: []const u8, repo: []const u8) !Release {
    const url_str = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/releases/latest", .{ owner, repo });
    defer allocator.free(url_str);
    return fetchReleaseByUrl(allocator, url_str);
}

pub fn fetchReleaseByTag(allocator: std.mem.Allocator, owner: []const u8, repo: []const u8, tag: []const u8) !Release {
    const url_str = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/releases/tags/{s}", .{ owner, repo, tag });
    defer allocator.free(url_str);
    return fetchReleaseByUrl(allocator, url_str);
}

fn fetchReleaseByUrl(allocator: std.mem.Allocator, url_str: []const u8) !Release {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const token = env_map.get("GITHUB_TOKEN");
    const uri = try std.Uri.parse(url_str);

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);

    try headers.append(allocator, .{ .name = "Accept", .value = "application/vnd.github.v3+json" });
    try headers.append(allocator, .{ .name = "User-Agent", .value = "binget" });

    var auth_header: []const u8 = undefined;
    if (token) |t| {
        auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{t});
        try headers.append(allocator, .{ .name = "Authorization", .value = auth_header });
    }
    defer if (token != null) allocator.free(auth_header);

    var req = try client.request(.GET, uri, .{
        .extra_headers = headers.items,
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var res = try req.receiveHead(&redirect_buf);

    if (res.head.status != .ok) {
        std.debug.print("GitHub API failed with status {}\n", .{res.head.status});
        return error.HttpFailed;
    }

    var transfer_buf: [8192]u8 = undefined;
    var decompress_buf: [65536]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const limit: std.io.Limit = @enumFromInt(1024 * 1024 * 5);
    const body = try res.readerDecompressing(&transfer_buf, &decompress, &decompress_buf).allocRemaining(allocator, limit);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const tag_name = root.get("tag_name").?.string;

    const assets_array = root.get("assets").?.array;
    var assets = try allocator.alloc(Release.Asset, assets_array.items.len);

    for (assets_array.items, 0..) |asset_val, i| {
        const asset_obj = asset_val.object;
        assets[i] = Release.Asset{
            .name = try allocator.dupe(u8, asset_obj.get("name").?.string),
            .browser_download_url = try allocator.dupe(u8, asset_obj.get("browser_download_url").?.string),
        };
    }

    return Release{
        .tag_name = try allocator.dupe(u8, tag_name),
        .assets = assets,
    };
}

pub fn freeRelease(allocator: std.mem.Allocator, release: Release) void {
    allocator.free(release.tag_name);
    for (release.assets) |asset| {
        allocator.free(asset.name);
        allocator.free(asset.browser_download_url);
    }
    allocator.free(release.assets);
}
