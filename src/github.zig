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
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    const token = env_map.get("GITHUB_TOKEN");

    const url_str = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/releases/latest", .{ owner, repo });
    defer allocator.free(url_str);

    const uri = try std.Uri.parse(url_str);
    var server_header_buffer: [8192]u8 = undefined;

    var headers = std.ArrayList(std.http.Header).init(allocator);
    defer headers.deinit();

    try headers.append(.{ .name = "User-Agent", .value = "binget/0.1.0 (Zig)" });
    try headers.append(.{ .name = "Accept", .value = "application/vnd.github.v3+json" });
    
    var auth_header: []u8 = undefined;
    if (token) |t| {
        auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{t});
        try headers.append(.{ .name = "Authorization", .value = auth_header });
    }
    defer if (token != null) allocator.free(auth_header);

    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buffer,
        .extra_headers = headers.items,
    });
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) {
        std.debug.print("GitHub API failed with status {}\n", .{req.response.status});
        return error.HttpFailed;
    }

    const body = try req.reader().readAllAlloc(allocator, 1024 * 1024 * 5); // Max 5MB release json
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
