const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");

/// Handle a file delete request
pub fn handleDelete(
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

    // Don't allow deleting root or empty path
    if (path.len == 0 or std.mem.eql(u8, path, ".")) {
        try http.sendBadRequest(stream, io, "Cannot delete root directory");
        return;
    }

    // Try to delete as a file first
    root_dir.deleteFile(io, path) catch |file_err| {
        // If not a file, try as directory
        if (file_err == error.IsDir or file_err == error.AccessDenied) {
            root_dir.deleteTree(io, path) catch |dir_err| {
                std.debug.print("Error deleting directory {s}: {s}\n", .{ path, @errorName(dir_err) });
                try http.sendInternalServerError(stream, io);
                return;
            };
        } else if (file_err == error.FileNotFound or file_err == error.NotFound) {
            try http.sendNotFound(stream, io);
            return;
        } else {
            std.debug.print("Error deleting file {s}: {s}\n", .{ path, @errorName(file_err) });
            try http.sendInternalServerError(stream, io);
            return;
        }
    };

    // Extract directory path for redirect
    const dir_path = std.fs.path.dirname(path);

    // Send success response
    const message = try std.fmt.allocPrint(allocator, "'{s}' deleted successfully", .{path});
    defer allocator.free(message);

    try sendDeleteSuccess(stream, io, message, dir_path);
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

/// Send a successful delete response
fn sendDeleteSuccess(stream: Io.net.Stream, io: Io, message: []const u8, dir_path: ?[]const u8) !void {
    try http.sendResponseHeaders(stream, io, .ok, &[_]struct { []const u8, []const u8 }{
        .{ "Content-Type", "text/html; charset=utf-8" },
    });

    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    var html = std.ArrayList(u8).initCapacity(allocator, 2048) catch return;

    try html.appendSlice(allocator,
        \\<!DOCTYPE html>
        \\<html><head>
        \\  <meta charset="utf-8">
        \\  <title>Delete Successful</title>
        \\  <style>
        \\    body { font-family: sans-serif; margin: 2em; text-align: center; }
        \\    .success { color: #28a745; }
        \\    a { color: #0366d6; text-decoration: none; }
        \\    a:hover { text-decoration: underline; }
        \\  </style>
        \\</head><body>
        \\  <h1 class="success">✓ Delete Successful</h1>
        \\  <p>
    );
    try html.appendSlice(allocator, message);

    if (dir_path) |dp| {
        try html.appendSlice(allocator, "</p>\n  <p><a href=\"/");
        try html.appendSlice(allocator, dp);
        try html.appendSlice(allocator, "\">← Back to directory listing</a></p>\n");
    } else {
        try html.appendSlice(allocator,
            \\</p>
            \\  <p><a href="/">← Back to directory listing</a></p>
        );
    }

    try html.appendSlice(allocator,
        \\</body></html>
    );

    var write_buf: [4096]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);
    try stream_writer.interface.writeAll(html.items);
    try stream_writer.interface.flush();
}
