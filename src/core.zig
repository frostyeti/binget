const std = @import("std");
const platform = @import("platform.zig");
const github = @import("github.zig");
const archive = @import("archive.zig");
const db = @import("db.zig");
const install_cmd = @import("install_cmd.zig");
const registry = @import("registry.zig");

pub fn getAssetArchAndOs() struct { arch: []const u8, os: []const u8 } {
    const builtin = @import("builtin");
    const os_tag = @tagName(builtin.os.tag);
    const arch_tag = @tagName(builtin.cpu.arch);
    return .{ .arch = arch_tag, .os = os_tag };
}

pub fn guessAsset(assets: []github.Release.Asset) ?[]const u8 {
    const sys = getAssetArchAndOs();
    
    var best_score: i32 = -1;
    var best_url: ?[]const u8 = null;

    for (assets) |asset| {
        var score: i32 = 0;
        const name = asset.name;

        if (std.ascii.indexOfIgnoreCase(name, sys.os) != null) score += 10;
        if (std.ascii.indexOfIgnoreCase(name, sys.arch) != null) score += 10;

        if (std.mem.eql(u8, sys.arch, "x86_64") and std.ascii.indexOfIgnoreCase(name, "amd64") != null) score += 10;
        if (std.mem.eql(u8, sys.os, "macos") and std.ascii.indexOfIgnoreCase(name, "darwin") != null) score += 10;
        if (std.mem.eql(u8, sys.os, "windows") and std.ascii.indexOfIgnoreCase(name, "win") != null) score += 10;

        if (std.ascii.endsWithIgnoreCase(name, ".tar.gz") or std.ascii.endsWithIgnoreCase(name, ".tgz")) score += 5;
        if (std.ascii.endsWithIgnoreCase(name, ".tar.xz") or std.ascii.endsWithIgnoreCase(name, ".txz")) score += 5;
        if (std.ascii.endsWithIgnoreCase(name, ".tar.bz2") or std.ascii.endsWithIgnoreCase(name, ".tbz2") or std.ascii.endsWithIgnoreCase(name, ".tar.bz")) score += 5;
        if (std.ascii.endsWithIgnoreCase(name, ".zip")) score += 5;
        if (std.ascii.endsWithIgnoreCase(name, ".deb")) {
            if (std.mem.eql(u8, sys.os, "linux")) {
                score += 15; // heavily prioritize .deb on linux to test the feature
            }
        }

        if (score > best_score and score >= 20) {
            best_score = score;
            best_url = asset.browser_download_url;
        }
    }
    return best_url;
}

pub fn installGithub(allocator: std.mem.Allocator, db_conn: db.Database, owner: []const u8, repo: []const u8, version_opt: ?[]const u8, mode: install_cmd.InstallMode) !void {
    std.debug.print("Fetching release info for {s}/{s}...\n", .{owner, repo});
    
    var release: github.Release = undefined;
    if (version_opt) |ver| {
        release = try github.fetchReleaseByTag(allocator, owner, repo, ver);
    } else {
        release = try github.fetchLatestRelease(allocator, owner, repo);
    }
    defer github.freeRelease(allocator, release);

    std.debug.print("Found release: {s}\n", .{release.tag_name});

    const url = guessAsset(release.assets) orelse {
        std.debug.print("Could not find a suitable asset for this OS/Arch.\n", .{});
        return error.NoAssetFound;
    };

    std.debug.print("Downloading: {s}\n", .{url});
    
    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);

    const tmp_dir_path = try std.fs.path.join(allocator, &.{ share_dir, ".tmp" });
    defer allocator.free(tmp_dir_path);

    try std.fs.cwd().makePath(tmp_dir_path);
    std.fs.cwd().deleteTree(tmp_dir_path) catch {};
    try std.fs.cwd().makePath(tmp_dir_path);
    defer std.fs.cwd().deleteTree(tmp_dir_path) catch {};

    const archive_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, "downloaded_archive" });
    defer allocator.free(archive_path);

    try archive.downloadFile(allocator, url, archive_path);

    const extract_dir = try std.fs.path.join(allocator, &.{ tmp_dir_path, "extracted" });
    defer allocator.free(extract_dir);
    try archive.extractArchive(allocator, archive_path, extract_dir, url);

    const pkg_dir = try std.fs.path.join(allocator, &.{ share_dir, "packages", repo, release.tag_name });
    defer allocator.free(pkg_dir);
    try std.fs.cwd().makePath(pkg_dir);

    const builtin = @import("builtin");
    const exe_name = if (builtin.os.tag == .windows) try std.fmt.allocPrint(allocator, "{s}.exe", .{repo}) else try allocator.dupe(u8, repo);
    defer allocator.free(exe_name);

    var found_exe: ?[]const u8 = null;
    
    var dir = try std.fs.cwd().openDir(extract_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var largest_file: ?[]const u8 = null;
    var largest_size: u64 = 0;

    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            if (std.mem.eql(u8, entry.basename, repo) or std.mem.eql(u8, entry.basename, exe_name)) {
                found_exe = try std.fs.path.join(allocator, &.{ extract_dir, entry.path });
                break;
            }
            const ext = std.fs.path.extension(entry.basename);
            var is_possible_bin = false;
            if (builtin.os.tag == .windows) {
                if (std.ascii.eqlIgnoreCase(ext, ".exe")) is_possible_bin = true;
            } else {
                if (ext.len == 0) is_possible_bin = true;
            }
            
            if (is_possible_bin) {
                const stat = try dir.statFile(entry.path);
                if (stat.size > largest_size) {
                    largest_size = stat.size;
                    if (largest_file) |lf| allocator.free(lf);
                    largest_file = try std.fs.path.join(allocator, &.{ extract_dir, entry.path });
                }
            }
        }
    }

    if (found_exe == null and largest_file != null) {
        found_exe = largest_file;
    } else if (largest_file != null) {
        allocator.free(largest_file.?);
    }

    if (found_exe) |exe_path| {
        defer allocator.free(exe_path);
        const final_exe_path = try std.fs.path.join(allocator, &.{ pkg_dir, exe_name });
        defer allocator.free(final_exe_path);

        try std.fs.cwd().rename(exe_path, final_exe_path);
        try archive.makeExecutable(final_exe_path);

        var bin_dir: []const u8 = undefined;
        var global = false;
        if (mode == .shim) {
            bin_dir = try std.fs.path.join(allocator, &.{ share_dir, "env", repo, release.tag_name });
        } else if (mode == .global) {
            bin_dir = try platform.getInstallDir(allocator, true);
            global = true;
        } else {
            bin_dir = try platform.getInstallDir(allocator, false);
        }
        defer allocator.free(bin_dir);
        
        try std.fs.cwd().makePath(bin_dir);

        const link_path = try std.fs.path.join(allocator, &.{ bin_dir, exe_name });
        defer allocator.free(link_path);

        std.fs.cwd().deleteFile(link_path) catch {};
        
        try std.fs.cwd().symLink(final_exe_path, link_path, .{});
        
        std.debug.print("Successfully installed {s} to {s}\n", .{ repo, link_path });

        const target = try std.fmt.allocPrint(allocator, "github.com/{s}/{s}", .{owner, repo});
        defer allocator.free(target);
        const name_z = try allocator.dupeZ(u8, target);
        defer allocator.free(name_z);
        const version_z = try allocator.dupeZ(u8, release.tag_name);
        defer allocator.free(version_z);
        const link_path_z = try allocator.dupeZ(u8, link_path);
        defer allocator.free(link_path_z);

        try db_conn.recordInstall(name_z, version_z, link_path_z, global);
    } else {
        std.debug.print("Could not find binary named '{s}' inside the archive.\n", .{repo});
    }
}

pub fn installRegistryId(allocator: std.mem.Allocator, db_conn: db.Database, id: []const u8, version_opt: ?[]const u8, mode: install_cmd.InstallMode) !void {
    std.debug.print("Resolving package '{s}' from default registry...\n", .{id});
    
    const vf = registry.fetchVersions(allocator, id) catch |err| {
        std.debug.print("Error: Package '{s}' not found in registry ({}).\n", .{id, err});
        return err;
    };
    defer registry.freeVersions(allocator, vf);
    
    var version_to_install = vf.latest;
    if (version_opt) |ver| {
        version_to_install = ver;
    }
    
    // Check if the requested version exists, and if it has CVEs
    var found_ver = false;
    for (vf.versions) |v| {
        if (std.mem.eql(u8, v.version, version_to_install)) {
            found_ver = true;
            if (v.cves) |cves| {
                if (cves.len > 0) {
                    std.debug.print("\n⚠️  WARNING: You are installing a version with known vulnerabilities:\n", .{});
                    for (cves) |c| {
                        std.debug.print("  - {s} (Score: {d}): {s}\n", .{c.id, c.score, c.description});
                    }
                    std.debug.print("\n", .{});
                }
            }
            break;
        }
    }
    
    if (!found_ver) {
        std.debug.print("Error: Version '{s}' not found for package '{s}'.\n", .{version_to_install, id});
        return error.VersionNotFound;
    }
    
    std.debug.print("Resolved version: {s}\n", .{version_to_install});
    
    // Fetch the correct manifest config
    const builtin = @import("builtin");
    const os_tag = @tagName(builtin.os.tag);
    const arch_tag = @tagName(builtin.cpu.arch);
    
    // Map zig standard names to our manifest nomenclature
    const os_str: []const u8 = os_tag;
    // We used to map macos to darwin, but binget-pkgs uses macos
    
    const arch_str: []const u8 = arch_tag;
    // We used to map x86_64 to amd64, but binget-pkgs uses x86_64

    const platform_id = try std.fmt.allocPrint(allocator, "{s}-{s}", .{os_str, arch_str});
    defer allocator.free(platform_id);
    
    std.debug.print("Fetching install manifest for {s}...\n", .{platform_id});
    const manifest = registry.fetchPlatformManifest(allocator, id, version_to_install, platform_id) catch |err| {
        std.debug.print("Error: Platform {s} is not supported for {s}@{s} ({}).\n", .{platform_id, id, version_to_install, err});
        return err;
    };
    defer registry.freePlatformManifest(allocator, manifest);
    
    var active_mode: ?registry.InstallModeConfig = null;
    var final_mode = mode;

    switch (mode) {
        .shim => {
            active_mode = manifest.install_modes.shim;
            if (active_mode == null) {
                active_mode = manifest.install_modes.user;
                final_mode = .user;
            }
        },
        .user => {
            active_mode = manifest.install_modes.user;
            if (active_mode == null) {
                active_mode = manifest.install_modes.shim;
                final_mode = .shim;
            }
        },
        .global => {
            active_mode = manifest.install_modes.global;
            if (active_mode == null) {
                active_mode = manifest.install_modes.user;
                final_mode = .user;
            }
            if (active_mode == null) {
                active_mode = manifest.install_modes.shim;
                final_mode = .shim;
            }
        },
    }
    
    if (active_mode == null) {
        std.debug.print("Error: No valid install mode is supported by the manifest for this platform.\n", .{});
        return error.UnsupportedInstallMode;
    }
    
    const config = active_mode.?;
    std.debug.print("Executing installation type: {s} (mode: {s})\n", .{config.type, @tagName(final_mode)});

    if (std.mem.eql(u8, config.type, "raw")) {
        try executeRawInstall(allocator, db_conn, id, version_to_install, config, final_mode);
    } else if (std.mem.eql(u8, config.type, "runtime")) {
        try executeRuntimeInstall(allocator, db_conn, id, version_to_install, config, final_mode);
    } else if (std.mem.eql(u8, config.type, "archive")) {
        try executeArchiveInstall(allocator, db_conn, id, version_to_install, config, final_mode);
    } else if (std.mem.eql(u8, config.type, "installer")) {
        std.debug.print("⚠️  Warning: '{s}' requires an interactive system installer (format: {s})\n", .{id, config.format orelse "unknown"});
        try executeNativeInstaller(allocator, db_conn, id, version_to_install, config, final_mode);
    } else if (std.mem.eql(u8, config.type, "apt") or std.mem.eql(u8, config.type, "winget") or std.mem.eql(u8, config.type, "choco") or std.mem.eql(u8, config.type, "brew")) {
        std.debug.print("Proxying installation to system package manager ({s})...\n", .{config.type});
        
        const pkg_name = if (config.package) |p| p else id;
        
        var argv: [][]const u8 = undefined;
        if (std.mem.eql(u8, config.type, "apt")) {
            argv = try allocator.alloc([]const u8, 4);
            argv[0] = "sudo";
            argv[1] = "apt-get";
            argv[2] = "install";
            argv[3] = "-y";
        } else if (std.mem.eql(u8, config.type, "brew")) {
            argv = try allocator.alloc([]const u8, 2);
            argv[0] = "brew";
            argv[1] = "install";
        } else if (std.mem.eql(u8, config.type, "winget")) {
            argv = try allocator.alloc([]const u8, 3);
            argv[0] = "winget";
            argv[1] = "install";
            argv[2] = "--exact";
        } else if (std.mem.eql(u8, config.type, "choco")) {
            argv = try allocator.alloc([]const u8, 3);
            argv[0] = "choco";
            argv[1] = "install";
            argv[2] = "-y";
        }
        defer allocator.free(argv);

        var final_argv = try allocator.alloc([]const u8, argv.len + 1);
        defer allocator.free(final_argv);
        for (argv, 0..) |arg, i| {
            final_argv[i] = arg;
        }
        final_argv[argv.len] = pkg_name;

        var child = std.process.Child.init(final_argv, allocator);
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        
        const term = try child.spawnAndWait();
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    std.debug.print("System package manager exited with code {}\n", .{code});
                    return error.SystemPackageManagerFailed;
                }
            },
            else => return error.SystemPackageManagerFailed,
        }
        std.debug.print("Successfully proxied install for {s}\n", .{id});
    } else {
        std.debug.print("Error: Unknown installer type '{s}'.\n", .{config.type});
        return error.UnknownInstallerType;
    }

    const post_install = @import("post_install.zig");
    try post_install.run(allocator, id, version_to_install, config, final_mode);
}

fn executeNativeInstaller(allocator: std.mem.Allocator, db_conn: db.Database, id: []const u8, version: []const u8, config: registry.InstallModeConfig, mode: install_cmd.InstallMode) !void {
    _ = db_conn;
    if (config.url == null) return error.InvalidManifest;
    
    if (mode == .shim) {
        std.debug.print("Error: Native installers do not support --shim mode. Use --user or --global.\n", .{});
        return error.UnsupportedInstallMode;
    }
    
    const url = config.url.?;
    const format = config.format orelse "unknown";
    
    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);

    const tmp_dir_path = try std.fs.path.join(allocator, &.{ share_dir, ".tmp" });
    defer allocator.free(tmp_dir_path);
    try std.fs.cwd().makePath(tmp_dir_path);
    
    const filename = try std.fmt.allocPrint(allocator, "{s}-{s}.{s}", .{id, version, format});
    defer allocator.free(filename);
    
    const download_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, filename });
    defer allocator.free(download_path);
    
    std.debug.print("Downloading installer to: {s}\n", .{download_path});
    try archive.downloadFile(allocator, url, download_path);
    
    std.debug.print("\n=== SYSTEM INSTALLER READY ===\n", .{});
    std.debug.print("To install '{s}', you must run the following downloaded file:\n", .{id});
    std.debug.print("-> {s}\n\n", .{download_path});
    
    if (std.mem.eql(u8, format, "msi")) {
        std.debug.print("Command: msiexec /i \"{s}\"\n", .{download_path});
    } else if (std.mem.eql(u8, format, "exe")) {
        std.debug.print("Command: \"{s}\"\n", .{download_path});
    } else if (std.mem.eql(u8, format, "dmg")) {
        std.debug.print("Command: hdiutil attach \"{s}\"\n", .{download_path});
    } else if (std.mem.eql(u8, format, "pkg")) {
        std.debug.print("Command: sudo installer -pkg \"{s}\" -target /\n", .{download_path});
    } else if (std.mem.eql(u8, format, "deb")) {
        std.debug.print("Command: sudo dpkg -i \"{s}\"\n", .{download_path});
    } else if (std.mem.eql(u8, format, "rpm")) {
        std.debug.print("Command: sudo rpm -i \"{s}\"\n", .{download_path});
    } else if (std.mem.eql(u8, format, "appimage")) {
        std.debug.print("Command: chmod +x \"{s}\" && \"{s}\"\n", .{download_path, download_path});
    }
    std.debug.print("==============================\n\n", .{});
}

fn executeRawInstall(allocator: std.mem.Allocator, db_conn: db.Database, id: []const u8, version: []const u8, config: registry.InstallModeConfig, mode: install_cmd.InstallMode) !void {
    if (config.url == null or config.bin == null or config.bin.?.len == 0) return error.InvalidManifest;
    
    const url = config.url.?;
    const bin_name = config.bin.?[0];
    
    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);

    var bin_dir: []const u8 = undefined;
    var is_global = false;
    if (mode == .shim) {
        bin_dir = try std.fs.path.join(allocator, &.{ share_dir, "env", id, version });
    } else if (mode == .global) {
        bin_dir = try platform.getInstallDir(allocator, true);
        is_global = true;
    } else {
        bin_dir = try platform.getInstallDir(allocator, false);
    }
    defer allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);
    
    const pkg_dir = try std.fs.path.join(allocator, &.{ share_dir, "packages", id, version });
    defer allocator.free(pkg_dir);
    
    std.fs.cwd().deleteTree(pkg_dir) catch {};
    try std.fs.cwd().makePath(pkg_dir);

    const dest_bin_name = std.fs.path.basename(bin_name);
    const target_exe = try std.fs.path.join(allocator, &.{ pkg_dir, dest_bin_name });
    defer allocator.free(target_exe);

    std.debug.print("Downloading: {s}\n", .{url});
    try archive.downloadFile(allocator, url, target_exe);
    try archive.makeExecutable(target_exe);

    const shim = @import("shim.zig");
    try shim.createShim(allocator, target_exe, bin_dir, dest_bin_name);

    std.debug.print("Installed {s} to {s}\n", .{dest_bin_name, bin_dir});

    const dest_path = try std.fs.path.join(allocator, &.{ bin_dir, dest_bin_name });
    defer allocator.free(dest_path);

    const id_z = try allocator.dupeZ(u8, id);
    defer allocator.free(id_z);
    const version_z = try allocator.dupeZ(u8, version);
    defer allocator.free(version_z);
    const dest_path_z = try allocator.dupeZ(u8, dest_path);
    defer allocator.free(dest_path_z);
    
    try db_conn.recordInstall(id_z, version_z, dest_path_z, is_global);
}

fn executeArchiveInstall(allocator: std.mem.Allocator, db_conn: db.Database, id: []const u8, version: []const u8, config: registry.InstallModeConfig, mode: install_cmd.InstallMode) !void {
    if (config.url == null or config.bin == null or config.bin.?.len == 0) return error.InvalidManifest;
    
    const url = config.url.?;
    
    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);

    var bin_dir: []const u8 = undefined;
    var is_global = false;
    if (mode == .shim) {
        bin_dir = try std.fs.path.join(allocator, &.{ share_dir, "env", id, version });
    } else if (mode == .global) {
        bin_dir = try platform.getInstallDir(allocator, true);
        is_global = true;
    } else {
        bin_dir = try platform.getInstallDir(allocator, false);
    }
    defer allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    const pkg_dir = try std.fs.path.join(allocator, &.{ share_dir, "packages", id, version });
    defer allocator.free(pkg_dir);
    
    std.fs.cwd().deleteTree(pkg_dir) catch {};
    try std.fs.cwd().makePath(pkg_dir);

    const tmp_dir_path = try std.fs.path.join(allocator, &.{ share_dir, "tmp", id, version });
    defer allocator.free(tmp_dir_path);

    std.fs.cwd().deleteTree(tmp_dir_path) catch {};
    try std.fs.cwd().makePath(tmp_dir_path);
    defer std.fs.cwd().deleteTree(tmp_dir_path) catch {};

    const archive_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, "downloaded_archive" });
    defer allocator.free(archive_path);

    std.debug.print("Downloading: {s}\n", .{url});
    try archive.downloadFile(allocator, url, archive_path);

    const extract_dir = pkg_dir;
    
    std.debug.print("Extracting to {s}...\n", .{extract_dir});
    try archive.extractArchive(allocator, archive_path, extract_dir, url);

    const shim = @import("shim.zig");

    // Create shims
    for (config.bin.?) |bin_name| {
        var target_exe: []const u8 = undefined;
        if (config.extract_dir) |ed| {
            target_exe = try std.fs.path.join(allocator, &.{ extract_dir, ed, bin_name });
        } else {
            target_exe = try std.fs.path.join(allocator, &.{ extract_dir, bin_name });
        }
        defer allocator.free(target_exe);

        try archive.makeExecutable(target_exe);

        const dest_bin_name = std.fs.path.basename(bin_name);
        try shim.createShim(allocator, target_exe, bin_dir, dest_bin_name);
        
        // Record install for the first binary
        if (std.mem.eql(u8, bin_name, config.bin.?[0])) {
            const dest_path = try std.fs.path.join(allocator, &.{ bin_dir, dest_bin_name });
            defer allocator.free(dest_path);

            const id_z = try allocator.dupeZ(u8, id);
            defer allocator.free(id_z);
            const version_z = try allocator.dupeZ(u8, version);
            defer allocator.free(version_z);
            const dest_path_z = try allocator.dupeZ(u8, dest_path);
            defer allocator.free(dest_path_z);
            
            try db_conn.recordInstall(id_z, version_z, dest_path_z, is_global);
        }
    }
}

pub fn installPackage(allocator: std.mem.Allocator, db_conn: db.Database, target: []const u8, global: bool) !void {
    // Deprecated adapter to not break main.zig before rewrite
    var split = std.mem.splitScalar(u8, target, '/');
    const owner = split.next() orelse return error.InvalidTarget;
    const repo = split.next() orelse return error.InvalidTarget;
    try installGithub(allocator, db_conn, owner, repo, null, if (global) .global else .user);
}

pub fn executeRuntimeInstall(allocator: std.mem.Allocator, db_conn: db.Database, id: []const u8, version: []const u8, config: registry.InstallModeConfig, mode: install_cmd.InstallMode) !void {
    if (config.url == null or config.bin == null or config.bin.?.len == 0) return error.InvalidManifest;
    
    const url = config.url.?;
    const builtin = @import("builtin");
    
    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);

    var bin_dir: []const u8 = undefined;
    var is_global = false;
    if (mode == .shim) {
        bin_dir = try std.fs.path.join(allocator, &.{ share_dir, "env", id, version });
    } else if (mode == .global) {
        bin_dir = try platform.getInstallDir(allocator, true);
        is_global = true;
    } else {
        bin_dir = try platform.getInstallDir(allocator, false);
    }
    defer allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    const tmp_dir_path = try std.fs.path.join(allocator, &.{ share_dir, "tmp", id, version });
    defer allocator.free(tmp_dir_path);

    std.fs.cwd().deleteTree(tmp_dir_path) catch {};
    try std.fs.cwd().makePath(tmp_dir_path);
    defer std.fs.cwd().deleteTree(tmp_dir_path) catch {};

    const archive_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, "downloaded_archive" });
    defer allocator.free(archive_path);

    std.debug.print("Downloading runtime: {s}\n", .{url});
    try archive.downloadFile(allocator, url, archive_path);

    const extract_dir = try std.fs.path.join(allocator, &.{ tmp_dir_path, "extracted" });
    defer allocator.free(extract_dir);
    
    std.debug.print("Extracting...\n", .{});
    try archive.extractArchive(allocator, archive_path, extract_dir, url);

    // For a runtime, we move the ENTIRE extracted dir to packages/<id>/<version>
    const package_dir = try std.fs.path.join(allocator, &.{ share_dir, "packages", id, version });
    defer allocator.free(package_dir);
    
    std.fs.cwd().deleteTree(package_dir) catch {};
    try std.fs.cwd().makePath(package_dir);
    
    var src_runtime_dir: []const u8 = undefined;
    if (config.extract_dir) |ed| {
        src_runtime_dir = try std.fs.path.join(allocator, &.{ extract_dir, ed });
    } else {
        src_runtime_dir = try allocator.dupe(u8, extract_dir);
    }
    defer allocator.free(src_runtime_dir);

    // Delete the target package_dir before renaming/installing, because rename target must not exist or be empty
    std.fs.cwd().deleteDir(package_dir) catch {};

    // Check if there is an install.sh script in the extracted directory
    const install_sh_path = try std.fs.path.join(allocator, &.{ src_runtime_dir, "install.sh" });
    defer allocator.free(install_sh_path);
    
    var installed_via_script = false;
    if (std.fs.cwd().access(install_sh_path, .{})) |_| {
        std.debug.print("Running installer script...\n", .{});
        
        var argv = [_][]const u8{
            "sh",
            install_sh_path,
            try std.fmt.allocPrint(allocator, "--prefix={s}", .{package_dir}),
        };
        defer allocator.free(argv[2]);

        var child = std.process.Child.init(&argv, allocator);
        child.cwd = src_runtime_dir;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        
        const term = try child.spawnAndWait();
        if (term != .Exited or term.Exited != 0) {
            std.debug.print("Installer script failed.\n", .{});
            return error.InstallerFailed;
        }
        installed_via_script = true;
    } else |_| {}
    
    if (!installed_via_script) {
        std.fs.cwd().rename(src_runtime_dir, package_dir) catch |err| {
            if (err == error.RenameAcrossMountPoints) {
                // we should copy tree, but for simplicity here we assume share_dir is same mount point
                std.debug.print("Error: Could not rename runtime directory (cross-device link not supported yet)\n", .{});
                return err;
            } else {
                return err;
            }
        };
    } else {
        std.fs.cwd().deleteTree(src_runtime_dir) catch {};
    }
    
    // Now create shims in bin_dir for each bin in config.bin
    for (config.bin.?) |bin_path| {
        // bin_path might be "bin/node" or just "go"
        // we just take the basename for the shim name
        const basename = std.fs.path.basename(bin_path);
        
        const actual_bin_path = try std.fs.path.join(allocator, &.{ package_dir, bin_path });
        defer allocator.free(actual_bin_path);
        
        try archive.makeExecutable(actual_bin_path);
        
        if (builtin.os.tag == .windows) {
            const shim_name = try std.fmt.allocPrint(allocator, "{s}.bat", .{basename});
            defer allocator.free(shim_name);
            const shim_path = try std.fs.path.join(allocator, &.{ bin_dir, shim_name });
            defer allocator.free(shim_path);
            
            var f = try std.fs.cwd().createFile(shim_path, .{});
            defer f.close();
            const shim_content = try std.fmt.allocPrint(allocator, "@echo off\n\"{s}\" %*\n", .{actual_bin_path});
            defer allocator.free(shim_content);
            try f.writeAll(shim_content);
        } else {
            const shim_path = try std.fs.path.join(allocator, &.{ bin_dir, basename });
            defer allocator.free(shim_path);
            
            var f = try std.fs.cwd().createFile(shim_path, .{});
            defer f.close();
            const shim_content = try std.fmt.allocPrint(allocator, "#!/bin/sh\nexec \"{s}\" \"$@\"\n", .{actual_bin_path});
            defer allocator.free(shim_content);
            try f.writeAll(shim_content);
            
            try archive.makeExecutable(shim_path);
            std.debug.print("Created shim {s} -> {s}\n", .{shim_path, actual_bin_path});
        }
        
        if (std.mem.eql(u8, bin_path, config.bin.?[0])) {
            const id_z = try allocator.dupeZ(u8, id);
            defer allocator.free(id_z);
            const version_z = try allocator.dupeZ(u8, version);
            defer allocator.free(version_z);
            const dest_path_z = try allocator.dupeZ(u8, actual_bin_path);
            defer allocator.free(dest_path_z);
            
            try db_conn.recordInstall(id_z, version_z, dest_path_z, is_global);
        }
    }
}
