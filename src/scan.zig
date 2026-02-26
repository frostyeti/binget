const std = @import("std");
const platform = @import("platform.zig");
const registry = @import("registry.zig");
const github = @import("github.zig");

fn urlEncode(allocator: std.mem.Allocator, in: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (in) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(allocator, c),
            else => {
                var buf: [3]u8 = undefined;
                _ = try std.fmt.bufPrint(&buf, "%{X:0>2}", .{c});
                try out.appendSlice(allocator, &buf);
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn scanPackage(allocator: std.mem.Allocator, id: []const u8, version_opt: ?[]const u8) !void {
    std.debug.print("Scanning package '{s}' via VirusTotal (placeholder implementation)...\n", .{id});
    
    // In a real implementation we would:
    // 1. Fetch the manifest
    // 2. Resolve the OS/Arch download URL for the target package
    // 3. Either download it and send it to VirusTotal API, or send the URL directly to VT
    
    var version: []const u8 = undefined;
    if (version_opt == null or std.mem.eql(u8, version_opt.?, "latest")) {
        const vf = try registry.fetchVersions(allocator, id);
        defer registry.freeVersions(allocator, vf);
        version = try allocator.dupe(u8, vf.latest);
    } else {
        version = try allocator.dupe(u8, version_opt.?);
    }
    defer allocator.free(version);
    
    std.debug.print("Resolved version: {s}\n", .{version});
    
    // Get the platform manifest
    const builtin = @import("builtin");
    const os_str = @tagName(builtin.os.tag);
    const arch_str = @tagName(builtin.cpu.arch);
    
    const platform_id = try std.fmt.allocPrint(allocator, "{s}-{s}", .{os_str, arch_str});
    defer allocator.free(platform_id);

    std.debug.print("Platform target: {s}\n", .{platform_id});
    
    const manifest = try registry.fetchPlatformManifest(allocator, id, version, platform_id);
    defer registry.freePlatformManifest(allocator, manifest);
    
    var dl_url: ?[]const u8 = null;
    
    if (manifest.install_modes.shim) |m| {
        dl_url = m.url;
    } else if (manifest.install_modes.user) |m| {
        dl_url = m.url;
    }
    
    if (dl_url) |url| {
        std.debug.print("Download URL found: {s}\n", .{url});
        std.debug.print("Submitting URL to VirusTotal API...\n", .{});
        
        // This is where VT API calls would happen:
        // curl --request POST \
        //  --url https://www.virustotal.com/api/v3/urls \
        //  --header "x-apikey: $VT_API_KEY" \
        //  --form url=$URL
        
        const vt_key = std.process.getEnvVarOwned(allocator, "VT_API_KEY") catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                std.debug.print("⚠️ VT_API_KEY environment variable not set. Please set it to enable actual scanning.\n", .{});
                return;
            }
            return err;
        };
        defer allocator.free(vt_key);
        
        std.debug.print("VT_API_KEY found, initiating scan...\n", .{});
        
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        const encoded_url = try urlEncode(allocator, url);
        defer allocator.free(encoded_url);

        const payload = try std.fmt.allocPrint(allocator, "url={s}", .{encoded_url});
        defer allocator.free(payload);

        var body_list = std.ArrayList(u8).empty;
        var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &body_list);

        const res = try client.fetch(.{
            .location = .{ .url = "https://www.virustotal.com/api/v3/urls" },
            .method = .POST,
            .payload = payload,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
                .{ .name = "x-apikey", .value = vt_key },
            },
            .response_writer = &aw.writer,
        });

        var final_list = aw.toArrayList();
        defer final_list.deinit(allocator);

        if (res.status == .ok) {
            std.debug.print("✅ Scan submitted successfully!\nVirusTotal Response:\n{s}\n", .{final_list.items});
        } else {
            std.debug.print("❌ Failed to submit scan to VirusTotal. Status: {d}\nResponse: {s}\n", .{res.status, final_list.items});
        }
    } else {
        std.debug.print("No download URL found in manifest for this platform. Nothing to scan.\n", .{});
    }
}
