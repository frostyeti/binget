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
    std.debug.print("Fetching release info for {s}/{s}...\n", .{ owner, repo });

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
    try archive.extractArchive(allocator, archive_path, extract_dir, url, null);

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
        if (mode == .global) {
            bin_dir = try platform.getInstallDir(allocator, true);
            global = true;
        } else {
            bin_dir = try platform.getInstallDir(allocator, false);
        }
        defer allocator.free(bin_dir);

        try std.fs.cwd().makePath(bin_dir);

        var link_path: []const u8 = undefined;

        if (mode == .shim) {
            const env_dir = try std.fs.path.join(allocator, &.{ share_dir, "env", repo, release.tag_name });
            defer allocator.free(env_dir);
            try std.fs.cwd().makePath(env_dir);

            const shim = @import("shim.zig");
            try shim.createShim(allocator, final_exe_path, env_dir, exe_name);
            try shim.createShim(allocator, final_exe_path, bin_dir, exe_name);

            link_path = try std.fs.path.join(allocator, &.{ bin_dir, exe_name });
            std.debug.print("Successfully installed {s} as global shim\n", .{repo});
        } else {
            link_path = try std.fs.path.join(allocator, &.{ bin_dir, exe_name });
            std.fs.cwd().deleteFile(link_path) catch {};

            // Move the binary directly to bin_dir
            std.fs.cwd().rename(final_exe_path, link_path) catch |err| {
                std.debug.print("Failed to move binary: {}\n", .{err});
                return err;
            };

            // Cleanup the package dir since it's a single binary install
            std.fs.cwd().deleteTree(pkg_dir) catch {};

            std.debug.print("Successfully installed {s} directly to {s}\n", .{ repo, link_path });
        }
        defer allocator.free(link_path);

        const target = try std.fmt.allocPrint(allocator, "github.com/{s}/{s}", .{ owner, repo });
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

fn selectMode(configs: []registry.InstallModeConfig, skip_prompts: bool) registry.InstallModeConfig {
    if (configs.len == 1 or skip_prompts) {
        return configs[0];
    }

    std.debug.print("\nMultiple installers available. Please select one:\n", .{});
    for (configs, 0..) |c, i| {
        const name = c.name orelse c.type;
        std.debug.print("[{}] {s} ({s})\n", .{ i, name, c.type });
    }

    const stdin = std.fs.File.stdin().deprecatedReader();
    var buf: [32]u8 = undefined;
    while (true) {
        std.debug.print("Selection [0]: ", .{});
        if (stdin.readUntilDelimiterOrEof(&buf, '\n') catch null) |line| {
            const trimmed = std.mem.trim(u8, line, "\r ");
            if (trimmed.len == 0) return configs[0];
            if (std.fmt.parseInt(usize, trimmed, 10)) |idx| {
                if (idx < configs.len) return configs[idx];
            } else |_| {}
        } else {
            return configs[0];
        }
        std.debug.print("Invalid selection.\n", .{});
    }
}

pub fn installRegistryId(allocator: std.mem.Allocator, db_conn: db.Database, id: []const u8, version_opt: ?[]const u8, mode: install_cmd.InstallMode, skip_prompts: bool) !void {
    std.debug.print("Resolving package '{s}' from default registry...\n", .{id});

    const vf = registry.fetchVersions(allocator, id) catch |err| {
        std.debug.print("Error: Package '{s}' not found in registry ({}).\n", .{ id, err });
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
                        std.debug.print("  - {s} (Score: {d}): {s}\n", .{ c.id, c.score, c.description });
                    }
                    std.debug.print("\n", .{});
                }
            }
            break;
        }
    }

    if (!found_ver) {
        std.debug.print("Error: Version '{s}' not found for package '{s}'.\n", .{ version_to_install, id });
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

    const platform_id = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ os_str, arch_str });
    defer allocator.free(platform_id);

    std.debug.print("Fetching install manifest for {s}...\n", .{platform_id});
    const manifest = registry.fetchPlatformManifest(allocator, id, version_to_install, platform_id) catch |err| {
        std.debug.print("Error: Platform {s} is not supported for {s}@{s} ({}).\n", .{ platform_id, id, version_to_install, err });
        return err;
    };
    defer registry.freePlatformManifest(allocator, manifest);

    var active_mode: ?registry.InstallModeConfig = null;
    var final_mode = mode;

    switch (mode) {
        .shim => {
            if (manifest.install_modes.shim) |m| {
                active_mode = selectMode(m, skip_prompts);
            }
            if (active_mode == null) {
                if (manifest.install_modes.user) |m| {
                    active_mode = selectMode(m, skip_prompts);
                    final_mode = .user;
                }
            }
        },
        .user => {
            if (manifest.install_modes.user) |m| {
                active_mode = selectMode(m, skip_prompts);
            }
            if (active_mode == null) {
                if (manifest.install_modes.shim) |m| {
                    active_mode = selectMode(m, skip_prompts);
                    final_mode = .shim;
                }
            }
        },
        .global => {
            if (manifest.install_modes.global) |m| {
                active_mode = selectMode(m, skip_prompts);
            }
            if (active_mode == null) {
                if (manifest.install_modes.user) |m| {
                    active_mode = selectMode(m, skip_prompts);
                    final_mode = .user;
                }
            }
            if (active_mode == null) {
                if (manifest.install_modes.shim) |m| {
                    active_mode = selectMode(m, skip_prompts);
                    final_mode = .shim;
                }
            }
        },
    }

    if (active_mode == null) {
        std.debug.print("Error: No valid install mode is supported by the manifest for this platform.\n", .{});
        return error.UnsupportedInstallMode;
    }

    const config = active_mode.?;
    std.debug.print("Executing installation type: {s} (mode: {s})\n", .{ config.type, @tagName(final_mode) });

    const hooks = @import("hooks.zig");
    try hooks.runHook(allocator, db_conn, .pre_install, id, version_to_install, skip_prompts);

    if (std.mem.eql(u8, config.type, "raw")) {
        try executeRawInstall(allocator, db_conn, id, version_to_install, config, final_mode);
    } else if (std.mem.eql(u8, config.type, "appimage")) {
        try executeAppImageInstall(allocator, db_conn, id, version_to_install, config, final_mode);
    } else if (std.mem.eql(u8, config.type, "runtime")) {
        try executeRuntimeInstall(allocator, db_conn, id, version_to_install, config, final_mode);
    } else if (std.mem.eql(u8, config.type, "archive")) {
        try executeArchiveInstall(allocator, db_conn, id, version_to_install, config, final_mode);
    } else if (std.mem.eql(u8, config.type, "build")) {
        try executeBuildInstall(allocator, db_conn, id, version_to_install, config, final_mode);
    } else if (std.mem.eql(u8, config.type, "installer")) {
        std.debug.print("⚠️  Warning: '{s}' requires an interactive system installer (format: {s})\n", .{ id, config.format orelse "unknown" });
        try executeNativeInstaller(allocator, db_conn, id, version_to_install, config, final_mode);
    } else if (std.mem.eql(u8, config.type, "flatpak")) {
        std.debug.print("Proxying installation to flatpak...\n", .{});
        const app_id = config.package orelse return error.MissingPackageForFlatpak;

        var argv = try allocator.alloc([]const u8, 6);
        defer allocator.free(argv);
        argv[0] = "flatpak";
        argv[1] = "install";
        argv[2] = if (final_mode == .global) "--system" else "--user";
        argv[3] = "--noninteractive";
        argv[4] = "flathub";
        argv[5] = app_id;

        var child = std.process.Child.init(argv, allocator);
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        const term = try child.spawnAndWait();
        switch (term) {
            .Exited => |code| {
                if (code != 0) return error.InstallFailed;
                const z_id = try allocator.dupeZ(u8, id);
                defer allocator.free(z_id);
                const z_version = try allocator.dupeZ(u8, version_to_install);
                defer allocator.free(z_version);
                try db_conn.recordInstall(z_id, z_version, "flatpak", final_mode == .global);
            },
            else => return error.InstallFailed,
        }
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

    try hooks.runHook(allocator, db_conn, .post_install, id, version_to_install, skip_prompts);
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

    const filename = try std.fmt.allocPrint(allocator, "{s}-{s}.{s}", .{ id, version, format });
    defer allocator.free(filename);

    const download_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, filename });
    defer allocator.free(download_path);

    std.debug.print("Downloading installer to: {s}\n", .{download_path});
    try archive.downloadFile(allocator, url, download_path);

    std.debug.print("Executing system installer...\n", .{});

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);

    var needs_uac = false;
    const builtin = @import("builtin");

    if (builtin.os.tag == .windows) {
        if (!platform.isAdmin() and mode == .global) {
            std.debug.print("⚠️  Global installation requested without Administrator privileges. Will prompt for UAC.\n", .{});
            needs_uac = true;
        }

        var exe_path: []const u8 = undefined;
        var args_str = std.ArrayList(u8).empty;
        defer args_str.deinit(allocator);

        if (std.mem.eql(u8, format, "msi")) {
            exe_path = "msiexec.exe";
            try args_str.writer(allocator).print("'/i', '\"{s}\"'", .{download_path});
            if (config.silent_args) |sargs| {
                for (sargs) |arg| {
                    try args_str.writer(allocator).print(", '{s}'", .{arg});
                }
            } else {
                try args_str.writer(allocator).print(", '/qb'", .{}); // Default silentish MSI arg
            }
        } else if (std.mem.eql(u8, format, "exe") or std.mem.eql(u8, format, "inno") or std.mem.eql(u8, format, "squirrel")) {
            exe_path = download_path;
            if (config.silent_args) |sargs| {
                for (sargs, 0..) |arg, i| {
                    if (i > 0) try args_str.writer(allocator).print(", ", .{});
                    try args_str.writer(allocator).print("'{s}'", .{arg});
                }
            } else if (std.mem.eql(u8, format, "inno")) {
                try args_str.writer(allocator).print("'/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'", .{});
            } else if (std.mem.eql(u8, format, "squirrel")) {
                try args_str.writer(allocator).print("'--silent'", .{});
            }
        } else {
            std.debug.print("\n=== SYSTEM INSTALLER READY ===\n", .{});
            std.debug.print("Automatic execution is not fully supported for this format ({s}) on this OS.\n", .{format});
            std.debug.print("To install '{s}', please run the following downloaded file manually:\n", .{id});
            std.debug.print("-> {s}\n", .{download_path});
            if (config.silent_args) |sargs| {
                std.debug.print("Recommended silent arguments: ", .{});
                for (sargs) |arg| {
                    std.debug.print("{s} ", .{arg});
                }
                std.debug.print("\n", .{});
            }
            std.debug.print("==============================\n\n", .{});
            return;
        }

        if (needs_uac) {
            try args.append(allocator, "powershell");
            try args.append(allocator, "-NoProfile");
            try args.append(allocator, "-Command");

            var ps_cmd = std.ArrayList(u8).empty;
            defer ps_cmd.deinit(allocator);
            if (args_str.items.len > 0) {
                try ps_cmd.writer(allocator).print("Start-Process '{s}' -ArgumentList {s} -Wait -Verb RunAs", .{ exe_path, args_str.items });
            } else {
                try ps_cmd.writer(allocator).print("Start-Process '{s}' -Wait -Verb RunAs", .{exe_path});
            }
            try args.append(allocator, try ps_cmd.toOwnedSlice(allocator));
        } else {
            if (std.mem.eql(u8, format, "msi")) {
                try args.append(allocator, "msiexec.exe");
                try args.append(allocator, "/i");
                try args.append(allocator, download_path);
                if (config.silent_args) |sargs| {
                    for (sargs) |arg| {
                        try args.append(allocator, arg);
                    }
                } else {
                    try args.append(allocator, "/qb");
                }
            } else {
                try args.append(allocator, download_path);
                if (config.silent_args) |sargs| {
                    for (sargs) |arg| {
                        try args.append(allocator, arg);
                    }
                } else if (std.mem.eql(u8, format, "inno")) {
                    try args.append(allocator, "/VERYSILENT");
                    try args.append(allocator, "/SUPPRESSMSGBOXES");
                    try args.append(allocator, "/NORESTART");
                } else if (std.mem.eql(u8, format, "squirrel")) {
                    try args.append(allocator, "--silent");
                }
            }
        }
    } else {
        std.debug.print("\n=== SYSTEM INSTALLER READY ===\n", .{});
        std.debug.print("Automatic execution is not fully supported for this format ({s}) on this OS.\n", .{format});
        std.debug.print("To install '{s}', please run the following downloaded file manually:\n", .{id});
        std.debug.print("-> {s}\n", .{download_path});
        if (config.silent_args) |sargs| {
            std.debug.print("Recommended silent arguments: ", .{});
            for (sargs) |arg| {
                std.debug.print("{s} ", .{arg});
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("==============================\n\n", .{});
        return;
    }

    var child = std.process.Child.init(args.items, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    std.debug.print("Running installer: ", .{});
    for (args.items) |arg| std.debug.print("{s} ", .{arg});
    std.debug.print("\n", .{});

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Installer exited with error code {}\n", .{code});
                return error.InstallFailed;
            }
            std.debug.print("Installation completed successfully.\n", .{});
        },
        else => {
            std.debug.print("Installer failed to complete.\n", .{});
            return error.InstallFailed;
        },
    }
}

fn executeAppImageInstall(allocator: std.mem.Allocator, db_conn: db.Database, id: []const u8, version: []const u8, config: registry.InstallModeConfig, mode: install_cmd.InstallMode) !void {
    // Treat an AppImage essentially like a raw binary install but with potential desktop integration
    try executeRawInstall(allocator, db_conn, id, version, config, mode);

    if (config.bin == null or config.bin.?.len == 0) return;

    // Attempt to extract .desktop and icons if on Linux
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux) return;

    std.debug.print("Extracting AppImage desktop integration files...\n", .{});

    const bin_name = config.bin.?[0];
    const dest_bin_name = std.fs.path.basename(bin_name);

    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);

    const pkg_dir = try std.fs.path.join(allocator, &.{ share_dir, "packages", id, version });
    defer allocator.free(pkg_dir);

    const target_exe = try std.fs.path.join(allocator, &.{ pkg_dir, dest_bin_name });
    defer allocator.free(target_exe);

    // Run the appimage with --appimage-extract
    var argv = try allocator.alloc([]const u8, 2);
    defer allocator.free(argv);
    argv[0] = target_exe;
    argv[1] = "--appimage-extract";

    var child = std.process.Child.init(argv, allocator);
    child.cwd = pkg_dir;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = child.spawnAndWait() catch |err| {
        std.debug.print("Warning: Failed to extract AppImage desktop files: {}\n", .{err});
        return;
    };

    switch (term) {
        .Exited => |code| {
            if (code == 0) {
                std.debug.print("AppImage contents extracted to {s}/squashfs-root\n", .{pkg_dir});
                // Note: full integration (copying .desktop to ~/.local/share/applications)
                // could be expanded here. For now we leave it extracted for shims/hooks.
            } else {
                std.debug.print("Warning: AppImage extraction exited with code {}\n", .{code});
            }
        },
        else => std.debug.print("Warning: AppImage extraction failed to complete.\n", .{}),
    }
}

fn executeRawInstall(allocator: std.mem.Allocator, db_conn: db.Database, id: []const u8, version: []const u8, config: registry.InstallModeConfig, mode: install_cmd.InstallMode) !void {
    if (config.url == null or config.bin == null or config.bin.?.len == 0) return error.InvalidManifest;

    const url = config.url.?;
    const bin_name = config.bin.?[0];

    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);

    var bin_dir: []const u8 = undefined;
    var is_global = false;
    if (mode == .global) {
        bin_dir = try platform.getInstallDir(allocator, true);
        is_global = true;
    } else {
        bin_dir = try platform.getInstallDir(allocator, false);
    }
    defer allocator.free(bin_dir);
    try std.fs.cwd().makePath(bin_dir);

    const dest_bin_name = std.fs.path.basename(bin_name);
    var dest_path: []const u8 = undefined;

    if (mode == .shim) {
        const env_dir = try std.fs.path.join(allocator, &.{ share_dir, "env", id, version });
        defer allocator.free(env_dir);
        try std.fs.cwd().makePath(env_dir);

        const pkg_dir = try std.fs.path.join(allocator, &.{ share_dir, "packages", id, version });
        defer allocator.free(pkg_dir);
        std.fs.cwd().deleteTree(pkg_dir) catch {};
        try std.fs.cwd().makePath(pkg_dir);

        const target_exe = try std.fs.path.join(allocator, &.{ pkg_dir, dest_bin_name });
        defer allocator.free(target_exe);

        std.debug.print("Downloading: {s}\n", .{url});
        try archive.downloadFile(allocator, url, target_exe);
        try archive.makeExecutable(target_exe);

        const shim = @import("shim.zig");
        try shim.createShim(allocator, target_exe, env_dir, dest_bin_name);
        try shim.createShim(allocator, target_exe, bin_dir, dest_bin_name);

        dest_path = try allocator.dupe(u8, target_exe);
        std.debug.print("Installed {s} as global shim\n", .{dest_bin_name});
    } else {
        const target_exe = try std.fs.path.join(allocator, &.{ bin_dir, dest_bin_name });

        std.debug.print("Downloading directly to {s}...\n", .{target_exe});
        try archive.downloadFile(allocator, url, target_exe);
        try archive.makeExecutable(target_exe);

        dest_path = try allocator.dupe(u8, target_exe);
    }
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
    if (mode == .global) {
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
    try archive.extractArchive(allocator, archive_path, extract_dir, url, config.format);

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

        if (mode == .shim) {
            const env_dir = try std.fs.path.join(allocator, &.{ share_dir, "env", id, version });
            defer allocator.free(env_dir);
            try std.fs.cwd().makePath(env_dir);

            try shim.createShim(allocator, target_exe, env_dir, dest_bin_name);
            try shim.createShim(allocator, target_exe, bin_dir, dest_bin_name);
        } else {
            try shim.createShim(allocator, target_exe, bin_dir, dest_bin_name);
        }

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
    try archive.extractArchive(allocator, archive_path, extract_dir, url, config.format);

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
            std.debug.print("Created shim {s} -> {s}\n", .{ shim_path, actual_bin_path });
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

fn executeBuildInstall(allocator: std.mem.Allocator, db_conn: db.Database, id: []const u8, version: []const u8, config: registry.InstallModeConfig, mode: install_cmd.InstallMode) !void {
    if (config.url == null) return error.InvalidManifest;

    const url = config.url.?;
    const format = config.format orelse "unknown";

    const engine = config.build_engine orelse "zig";
    std.debug.print("Build engine configured as '{s}'\n", .{engine});

    const share_dir = try platform.getBingetShareDir(allocator);
    defer allocator.free(share_dir);

    const tmp_dir_path = try std.fs.path.join(allocator, &.{ share_dir, ".tmp" });
    defer allocator.free(tmp_dir_path);
    try std.fs.cwd().makePath(tmp_dir_path);

    const archive_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, try std.fmt.allocPrint(allocator, "{s}-src.{s}", .{ id, format }) });
    defer allocator.free(archive_path);

    std.debug.print("Downloading source: {s}\n", .{url});
    try archive.downloadFile(allocator, url, archive_path);
    defer std.fs.cwd().deleteFile(archive_path) catch {};

    const extract_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, try std.fmt.allocPrint(allocator, "{s}-src-extracted", .{id}) });
    defer allocator.free(extract_path);
    std.fs.cwd().deleteTree(extract_path) catch {};
    try std.fs.cwd().makePath(extract_path);

    std.debug.print("Extracting source...\n", .{});
    try archive.extractArchive(allocator, archive_path, extract_path, url, null);

    // Resolve where the build should actually happen (maybe a sub-directory in the tarball)
    var build_dir = try allocator.dupe(u8, extract_path);
    defer allocator.free(build_dir);
    if (config.extract_dir) |ed| {
        const temp = build_dir;
        build_dir = try std.fs.path.join(allocator, &.{ temp, ed });
        allocator.free(temp);
    }

    std.debug.print("Compiling from source in {s}...\n", .{build_dir});

    // Construct command
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, engine);

    if (config.build_args) |args| {
        for (args) |arg| {
            try argv.append(allocator, arg);
        }
    }

    // Run build
    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = build_dir;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("Build failed with code {}\n", .{code});
                return error.BuildFailed;
            }
        },
        else => return error.BuildFailed,
    }

    std.debug.print("Build completed successfully.\n", .{});

    // Now copy binaries over
    const package_dir = try std.fs.path.join(allocator, &.{ share_dir, "packages", id, version });
    defer allocator.free(package_dir);

    try std.fs.cwd().makePath(package_dir);

    // Use bin mapping from manifest
    if (config.bin) |bins| {
        for (bins) |bin_src_path| {
            const full_bin_src = try std.fs.path.join(allocator, &.{ build_dir, bin_src_path });
            defer allocator.free(full_bin_src);

            const dest_bin_name = std.fs.path.basename(bin_src_path);
            const full_bin_dest = try std.fs.path.join(allocator, &.{ package_dir, dest_bin_name });
            defer allocator.free(full_bin_dest);

            try std.fs.cwd().copyFile(full_bin_src, std.fs.cwd(), full_bin_dest, .{});

            // Mark executable
            const builtin = @import("builtin");
            if (builtin.os.tag != .windows) {
                try archive.makeExecutable(full_bin_dest);
            }

            // Create shims
            var bin_dir: []const u8 = undefined;
            if (mode == .shim) {
                bin_dir = try std.fs.path.join(allocator, &.{ share_dir, "env", id, version });
            } else if (mode == .global) {
                bin_dir = try platform.getInstallDir(allocator, true);
            } else {
                bin_dir = try platform.getInstallDir(allocator, false);
            }
            defer allocator.free(bin_dir);
            try std.fs.cwd().makePath(bin_dir);

            const shim = @import("shim.zig");
            try shim.createShim(allocator, full_bin_dest, bin_dir, dest_bin_name);
            std.debug.print("Installed compiled binary {s} to {s}\n", .{ dest_bin_name, bin_dir });

            const dest_path_z = try allocator.dupeZ(u8, bin_dir);
            defer allocator.free(dest_path_z);

            const id_z = try allocator.dupeZ(u8, id);
            defer allocator.free(id_z);
            const version_z = try allocator.dupeZ(u8, version);
            defer allocator.free(version_z);

            const is_global = if (mode == .global) true else false;
            try db_conn.recordInstall(id_z, version_z, dest_path_z, is_global);
        }
    }

    std.fs.cwd().deleteTree(extract_path) catch {};
}
