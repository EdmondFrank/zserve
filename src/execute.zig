const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");

/// Handle a shell script execution request
pub fn handleExecute(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    root_dir: Io.Dir,
    path: []const u8,
) !void {
    // Validate path (no directory traversal)
    if (containsTraversal(path)) {
        try http.sendBadRequest(stream, io, "Invalid path: directory traversal not allowed");
        return;
    }

    // Don't allow empty path
    if (path.len == 0) {
        try http.sendBadRequest(stream, io, "No file specified");
        return;
    }

    // Check if file is a shell script
    if (!isShellScript(path)) {
        try http.sendBadRequest(stream, io, "Only shell scripts can be executed");
        return;
    }

    // Execute the script using spawnPath which resolves relative to root_dir
    const result = executeScript(io, allocator, root_dir, path) catch |err| {
        std.debug.print("Error executing script {s}: {s}\n", .{ path, @errorName(err) });
        try sendExecuteError(stream, io, path, err);
        return;
    };

    // Send success response with output
    try sendExecuteResult(stream, io, allocator, path, result.stdout, result.stderr, result.exit_code);
}

/// Check if a file is a shell script based on extension
fn isShellScript(path: []const u8) bool {
    const shell_extensions = &[_][]const u8{
        ".sh", ".bash", ".zsh", ".fish", ".ksh",
    };

    for (shell_extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) {
            return true;
        }
    }
    return false;
}

/// Check if a path contains directory traversal attempts
fn containsTraversal(path: []const u8) bool {
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        const c = path[i];
        if (c == '.' and i + 1 < path.len and path[i + 1] == '.') {
            const at_start = i == 0;
            const preceded_by_sep = i > 0 and (path[i - 1] == '/' or path[i - 1] == '\\');
            const at_end = i + 2 == path.len;
            const followed_by_sep = i + 2 < path.len and (path[i + 2] == '/' or path[i + 2] == '\\');

            if ((at_start or preceded_by_sep) and (at_end or followed_by_sep)) {
                return true;
            }
        }
    }
    return false;
}

const ExecuteResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
};

/// Execute a shell script and capture output
fn executeScript(io: Io, allocator: std.mem.Allocator, root_dir: Io.Dir, path: []const u8) !ExecuteResult {
    // First, verify the file exists by trying to open it from root_dir
    const file = root_dir.openFile(io, path, .{}) catch |err| {
        return err;
    };
    file.close(io);

    // Get the real path of the root directory
    // Platform-specific: macOS uses F.GETPATH, Linux uses /proc/self/fd
    const root_path = blk: {
        const native_os = @import("builtin").os.tag;
        if (native_os == .macos) {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const result = std.posix.system.fcntl(root_dir.handle, std.posix.F.GETPATH, @intFromPtr(&path_buf));
            if (result < 0) {
                return error.FileNotFound;
            }
            // Find the null terminator to get the actual path length
            var path_len: usize = 0;
            while (path_len < path_buf.len and path_buf[path_len] != 0) {
                path_len += 1;
            }
            break :blk try allocator.dupe(u8, path_buf[0..path_len]);
        } else {
            // Linux: use /proc/self/fd/<fd>
            var fd_path_buf: [64]u8 = undefined;
            const fd_path = try std.fmt.bufPrint(&fd_path_buf, "/proc/self/fd/{d}", .{root_dir.handle});
            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            const link_len = try Io.Dir.readLinkAbsolute(io, fd_path, &link_buf);
            break :blk try allocator.dupe(u8, link_buf[0..link_len]);
        }
    };
    defer allocator.free(root_path);

    // Construct the absolute path
    const abs_path = try std.fs.path.join(allocator, &[_][]const u8{ root_path, path });
    defer allocator.free(abs_path);

    // Use std.process.run for simple blocking execution with output capture
    const result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{abs_path},
    });

    const exit_code: u8 = switch (result.term) {
        .exited => |code| @intCast(code),
        else => 1,
    };

    return ExecuteResult{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exit_code,
    };
}

/// Send an error response when execution fails
fn sendExecuteError(stream: Io.net.Stream, io: Io, path: []const u8, err: anyerror) !void {
    try http.sendResponseHeaders(stream, io, .ok, &[_]struct { []const u8, []const u8 }{
        .{ "Content-Type", "text/html; charset=utf-8" },
    });

    var buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    var html = std.ArrayList(u8).initCapacity(allocator, 4096) catch return;

    try html.appendSlice(allocator,
        \\<!DOCTYPE html>
        \\<html><head>
        \\  <meta charset="utf-8">
        \\  <title>Execution Failed</title>
        \\  <style>
        \\    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 2em; background: #f6f8fa; }
        \\    .header { background: linear-gradient(135deg, #dc2626 0%, #b91c1c 100%); color: white; padding: 1em 2em; margin: -2em -2em 2em -2em; box-shadow: 0 2px 8px rgba(220,38,38,0.3); }
        \\    .header h1 { margin: 0; font-size: 1.2em; font-weight: 500; }
        \\    .error { background: #fef2f2; border: 1px solid #fecaca; border-radius: 8px; padding: 1em; margin: 1em 0; color: #991b1b; }
        \\    a { color: #0366d6; text-decoration: none; }
        \\    a:hover { text-decoration: underline; }
        \\  </style>
        \\</head><body>
        \\  <div class="header">
        \\    <h1>❌ Execution Failed</h1>
        \\  </div>
        \\  <p>Failed to execute: <strong>
    );
    try html.appendSlice(allocator, path);
    try html.appendSlice(allocator, "</strong></p>\n  <div class=\"error\">Error: ");
    try html.appendSlice(allocator, @errorName(err));
    try html.appendSlice(allocator,
        \\</div>
        \\  <p><a href="/">← Back to directory listing</a></p>
        \\</body></html>
    );

    var write_buf: [8192]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);
    try stream_writer.interface.writeAll(html.items);
    try stream_writer.interface.flush();
}

/// Send the execution result as an HTML page
fn sendExecuteResult(
    stream: Io.net.Stream,
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
) !void {
    try http.sendResponseHeaders(stream, io, .ok, &[_]struct { []const u8, []const u8 }{
        .{ "Content-Type", "text/html; charset=utf-8" },
    });

    // Escape HTML in output
    const escaped_stdout = try escapeHtml(allocator, stdout);
    defer allocator.free(escaped_stdout);
    const escaped_stderr = try escapeHtml(allocator, stderr);
    defer allocator.free(escaped_stderr);

    const dir_path = std.fs.path.dirname(path);

    var html = std.ArrayList(u8).initCapacity(allocator, 8192) catch return;
    defer html.deinit(allocator);

    const status_class = if (exit_code == 0) "success" else "error";
    const status_icon = if (exit_code == 0) "✓" else "✗";
    const status_text = if (exit_code == 0) "Success" else "Failed";

    try html.appendSlice(allocator,
        \\<!DOCTYPE html>
        \\<html><head>
        \\  <meta charset="utf-8">
        \\  <title>Execution Result: 
    );
    try html.appendSlice(allocator, path);
    try html.appendSlice(allocator,
        \\</title>
        \\  <style>
        \\    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 0; background: #f6f8fa; }
        \\    .header { background: linear-gradient(135deg, #3b82f6 0%, #2563eb 100%); color: white; padding: 1em 2em; box-shadow: 0 2px 8px rgba(37,99,235,0.3); display: flex; align-items: center; justify-content: space-between; }
        \\    .header h1 { margin: 0; font-size: 1.2em; font-weight: 500; }
        \\    .header a { color: white; text-decoration: none; padding: 0.5em 1em; background: rgba(255,255,255,0.2); border-radius: 6px; transition: background 0.2s; }
        \\    .header a:hover { background: rgba(255,255,255,0.3); }
        \\    .container { max-width: 1200px; margin: 2em auto; padding: 0 2em; }
        \\    .status { display: inline-flex; align-items: center; gap: 8px; padding: 0.5em 1em; border-radius: 8px; font-weight: 500; margin-bottom: 1em; }
        \\    .status.success { background: #dcfce7; color: #166534; }
        \\    .status.error { background: #fef2f2; color: #991b1b; }
        \\    .output-section { background: white; border-radius: 12px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin: 1em 0; overflow: hidden; }
        \\    .output-header { background: #f1f5f9; padding: 0.75em 1em; font-weight: 500; border-bottom: 1px solid #e2e8f0; }
        \\    pre { margin: 0; padding: 1em; overflow-x: auto; font-size: 14px; line-height: 1.6; background: #1e293b; color: #e2e8f0; }
        \\    pre.stderr { background: #450a0a; color: #fecaca; }
        \\    code { font-family: "SF Mono", Monaco, Inconsolata, "Fira Code", monospace; }
        \\  </style>
        \\</head><body>
        \\  <div class="header">
        \\    <div>
        \\      <h1>▶️ Executed: 
    );
    try html.appendSlice(allocator, path);
    try html.appendSlice(allocator, "</h1>\n    </div>\n    <a href=\"/");
    if (dir_path) |dp| {
        try html.appendSlice(allocator, dp);
    }
    try html.appendSlice(allocator, "\">← Back to directory</a>\n  </div>\n  <div class=\"container\">\n    <div class=\"status ");
    try html.appendSlice(allocator, status_class);
    try html.appendSlice(allocator, "\">");

    try html.appendSlice(allocator, status_icon);
    try html.appendSlice(allocator, " ");
    try html.appendSlice(allocator, status_text);
    try html.appendSlice(allocator, " (exit code: ");
    var exit_code_buf: [16]u8 = undefined;
    const exit_code_str = std.fmt.bufPrint(&exit_code_buf, "{d}", .{exit_code}) catch "?";
    try html.appendSlice(allocator, exit_code_str);
    try html.appendSlice(allocator, ")</div>\n");

    // Show stdout if present
    if (escaped_stdout.len > 0) {
        try html.appendSlice(allocator,
            \\    <div class="output-section">
            \\      <div class="output-header">Standard Output</div>
            \\      <pre><code>
        );
        try html.appendSlice(allocator, escaped_stdout);
        try html.appendSlice(allocator, "</code></pre>\n    </div>\n");
    }

    // Show stderr if present
    if (escaped_stderr.len > 0) {
        try html.appendSlice(allocator,
            \\    <div class="output-section">
            \\      <div class="output-header">Standard Error</div>
            \\      <pre class="stderr"><code>
        );
        try html.appendSlice(allocator, escaped_stderr);
        try html.appendSlice(allocator, "</code></pre>\n    </div>\n");
    }

    try html.appendSlice(allocator,
        \\  </div>
        \\</body></html>
    );

    var write_buf: [8192]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);
    try stream_writer.interface.writeAll(html.items);
    try stream_writer.interface.flush();
}

/// Escape HTML special characters
fn escapeHtml(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var output = std.ArrayList(u8).initCapacity(allocator, input.len * 2) catch return error.OutOfMemory;
    defer output.deinit(allocator);

    for (input) |c| {
        switch (c) {
            '&' => try output.appendSlice(allocator, "&amp;"),
            '<' => try output.appendSlice(allocator, "&lt;"),
            '>' => try output.appendSlice(allocator, "&gt;"),
            '"' => try output.appendSlice(allocator, "&quot;"),
            '\'' => try output.appendSlice(allocator, "&#x27;"),
            else => try output.append(allocator, c),
        }
    }

    return output.toOwnedSlice(allocator);
}
