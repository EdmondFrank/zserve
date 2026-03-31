const std = @import("std");
const Io = std.Io;

pub const FileStatus = enum {
    modified,
    added,
    deleted,
    renamed,
    untracked,
    staged_modified,
    staged_added,
    staged_deleted,
};

pub const GitFile = struct {
    status: FileStatus,
    path: []const u8,
    old_path: ?[]const u8, // for renames
};

pub const GitStatus = struct {
    branch: []const u8,
    files: []GitFile,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GitStatus) void {
        self.allocator.free(self.branch);
        for (self.files) |f| {
            self.allocator.free(f.path);
            if (f.old_path) |op| self.allocator.free(op);
        }
        self.allocator.free(self.files);
    }
};

/// Check if a directory is a git repository by looking for .git
pub fn isGitRepo(io: Io, dir: Io.Dir) bool {
    const git_dir = dir.openDir(io, ".git", .{}) catch return false;
    git_dir.close(io);
    return true;
}

/// Get the real path of a directory (cross-platform: macOS + Linux)
fn getDirRealPath(io: Io, allocator: std.mem.Allocator, dir: Io.Dir) ![]const u8 {
    const native_os = @import("builtin").os.tag;
    if (native_os == .macos) {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const result = std.posix.system.fcntl(dir.handle, std.posix.F.GETPATH, @intFromPtr(&path_buf));
        if (result < 0) return error.FileNotFound;
        var path_len: usize = 0;
        while (path_len < path_buf.len and path_buf[path_len] != 0) path_len += 1;
        return allocator.dupe(u8, path_buf[0..path_len]);
    } else {
        var fd_path_buf: [64]u8 = undefined;
        const fd_path = try std.fmt.bufPrint(&fd_path_buf, "/proc/self/fd/{d}", .{dir.handle});
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const link_len = try Io.Dir.readLinkAbsolute(io, fd_path, &link_buf);
        return allocator.dupe(u8, link_buf[0..link_len]);
    }
}

/// Run a git command in the given directory and return stdout (caller owns)
fn runGit(io: Io, allocator: std.mem.Allocator, root_dir: Io.Dir, args: []const []const u8) ![]const u8 {
    const root_path = try getDirRealPath(io, allocator, root_dir);
    defer allocator.free(root_path);

    // Build argv: ["git", "-C", root_path, ...args]
    var argv = std.ArrayList([]const u8).initCapacity(allocator, args.len + 3) catch return error.OutOfMemory;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "-C");
    try argv.append(allocator, root_path);
    for (args) |arg| {
        try argv.append(allocator, arg);
    }

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
    }) catch |err| {
        std.debug.print("git command failed: {s}\n", .{@errorName(err)});
        return error.GitCommandFailed;
    };
    defer allocator.free(result.stderr);

    return result.stdout; // caller owns
}

/// Get git status: branch name and list of changed files
pub fn getGitStatus(io: Io, allocator: std.mem.Allocator, root_dir: Io.Dir) !GitStatus {
    // Get branch name
    const branch_raw = runGit(io, allocator, root_dir, &[_][]const u8{
        "rev-parse", "--abbrev-ref", "HEAD",
    }) catch |err| blk: {
        std.debug.print("Failed to get branch: {s}\n", .{@errorName(err)});
        break :blk try allocator.dupe(u8, "unknown");
    };
    defer allocator.free(branch_raw);
    const branch = try allocator.dupe(u8, std.mem.trim(u8, branch_raw, " \t\r\n"));

    // Get status --porcelain
    const status_raw = runGit(io, allocator, root_dir, &[_][]const u8{
        "status", "--porcelain=v1",
    }) catch |err| blk: {
        std.debug.print("Failed to get status: {s}\n", .{@errorName(err)});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(status_raw);

    var files = std.ArrayList(GitFile).initCapacity(allocator, 16) catch return error.OutOfMemory;
    errdefer {
        for (files.items) |f| {
            allocator.free(f.path);
            if (f.old_path) |op| allocator.free(op);
        }
        files.deinit(allocator);
    }

    // Parse porcelain output: "XY path" or "XY old_path -> new_path"
    var lines = std.mem.splitScalar(u8, status_raw, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue; // need at least "XY p"
        const x = line[0]; // index status
        const y = line[1]; // worktree status
        const path_part = line[3..]; // skip "XY "

        // Determine status
        const status: FileStatus = blk: {
            if (x == '?' and y == '?') break :blk .untracked;
            if (x == 'R') break :blk .renamed;
            if (x == 'A') break :blk .staged_added;
            if (x == 'D' and y == ' ') break :blk .staged_deleted;
            if (x == 'M') break :blk .staged_modified;
            if (y == 'M') break :blk .modified;
            if (y == 'D') break :blk .deleted;
            if (y == 'A') break :blk .added;
            break :blk .modified;
        };

        // Handle renames: "old_path -> new_path"
        if (status == .renamed) {
            if (std.mem.indexOf(u8, path_part, " -> ")) |arrow_idx| {
                const old = try allocator.dupe(u8, path_part[0..arrow_idx]);
                const new = try allocator.dupe(u8, path_part[arrow_idx + 4 ..]);
                try files.append(allocator, .{
                    .status = status,
                    .path = new,
                    .old_path = old,
                });
            } else {
                try files.append(allocator, .{
                    .status = status,
                    .path = try allocator.dupe(u8, path_part),
                    .old_path = null,
                });
            }
        } else {
            try files.append(allocator, .{
                .status = status,
                .path = try allocator.dupe(u8, path_part),
                .old_path = null,
            });
        }
    }

    return GitStatus{
        .branch = branch,
        .files = try files.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Get the diff for a specific file. Returns owned slice.
pub fn getFileDiff(io: Io, allocator: std.mem.Allocator, root_dir: Io.Dir, file_path: []const u8, is_untracked: bool) ![]const u8 {
    if (is_untracked) {
        // For untracked files, diff against /dev/null
        const diff = runGit(io, allocator, root_dir, &[_][]const u8{
            "diff", "--no-index", "/dev/null", file_path,
        }) catch |err| {
            std.debug.print("Failed to diff untracked file: {s}\n", .{@errorName(err)});
            return allocator.dupe(u8, "(no diff available)");
        };
        return diff;
    } else {
        // For tracked files, diff HEAD vs working tree (includes staged)
        const diff = runGit(io, allocator, root_dir, &[_][]const u8{
            "diff", "HEAD", "--", file_path,
        }) catch |err| {
            std.debug.print("Failed to diff file: {s}\n", .{@errorName(err)});
            return allocator.dupe(u8, "(no diff available)");
        };
        if (diff.len == 0) {
            allocator.free(diff);
            // Try staged diff
            return runGit(io, allocator, root_dir, &[_][]const u8{
                "diff", "--cached", "--", file_path,
            }) catch allocator.dupe(u8, "(no diff available)");
        }
        return diff;
    }
}

/// Get recent git log (last 20 commits). Returns owned slice.
pub fn getGitLog(io: Io, allocator: std.mem.Allocator, root_dir: Io.Dir) ![]const u8 {
    return runGit(io, allocator, root_dir, &[_][]const u8{
        "log", "--oneline", "--graph", "--decorate", "-20",
    }) catch allocator.dupe(u8, "(no log available)");
}
