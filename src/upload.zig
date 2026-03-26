const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");

const MAX_FILE_SIZE = 100 * 1024 * 1024; // 100MB limit

/// Handle a file upload request
pub fn handleUpload(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    root_dir: Io.Dir,
    request: http.Request,
    request_body: []const u8,
) !void {
    // Get Content-Type header
    const content_type = request.headers.get("Content-Type") orelse {
        try http.sendBadRequest(stream, io, "Missing Content-Type header");
        return;
    };

    // Check for multipart/form-data
    if (!std.mem.startsWith(u8, content_type, "multipart/form-data")) {
        try http.sendBadRequest(stream, io, "Content-Type must be multipart/form-data");
        return;
    }

    // Extract boundary
    const boundary = extractBoundary(content_type) orelse {
        try http.sendBadRequest(stream, io, "Missing boundary in Content-Type");
        return;
    };

    // Parse multipart body
    const form_data = parseMultipartBody(allocator, request_body, boundary) catch |err| {
        switch (err) {
            error.NoFileField => try http.sendBadRequest(stream, io, "No file field found in request"),
            error.FileTooLarge => try http.sendBadRequest(stream, io, "File too large"),
            else => try http.sendBadRequest(stream, io, "Invalid multipart body"),
        }
        return;
    };
    defer allocator.free(form_data.filename);
    defer allocator.free(form_data.content);
    defer if (form_data.path) |path| allocator.free(path);

    // Validate path (no directory traversal)
    if (form_data.path) |path| {
        if (containsTraversal(path)) {
            try http.sendBadRequest(stream, io, "Invalid path: directory traversal not allowed");
            return;
        }
    }

    // Validate filename (no directory traversal)
    if (containsTraversal(form_data.filename)) {
        try http.sendBadRequest(stream, io, "Invalid filename: directory traversal not allowed");
        return;
    }

    // Construct full path (path + filename)
    const full_path = if (form_data.path) |path| blk: {
        if (path.len == 0) {
            break :blk form_data.filename;
        }
        // Join path and filename
        const joined = try std.fs.path.join(allocator, &[_][]const u8{ path, form_data.filename });
        break :blk joined;
    } else form_data.filename;
    defer if (form_data.path != null and full_path.ptr != form_data.filename.ptr) allocator.free(full_path);

    // Write file to disk
    writeUploadedFile(io, allocator, stream, root_dir, full_path, form_data.content) catch |err| {
        std.debug.print("Error writing file: {s}\n", .{@errorName(err)});
        try http.sendInternalServerError(stream, io);
        return;
    };
}

const FileData = struct {
    filename: []const u8,
    content: []const u8,
    path: ?[]const u8 = null,
};

/// Extract boundary from Content-Type header
fn extractBoundary(content_type: []const u8) ?[]const u8 {
    const prefix = "boundary=";
    const idx = std.mem.indexOf(u8, content_type, prefix) orelse return null;
    const start = idx + prefix.len;

    // Handle quoted boundary
    if (start < content_type.len and content_type[start] == '"') {
        const end = std.mem.indexOfScalarPos(u8, content_type, start + 1, '"') orelse return null;
        return content_type[start + 1 .. end];
    }

    // Unquoted boundary (take until semicolon or end)
    const end = std.mem.indexOfScalarPos(u8, content_type, start, ';') orelse content_type.len;
    return std.mem.trim(u8, content_type[start..end], " \t");
}

/// Parse multipart/form-data body to extract file and path
fn parseMultipartBody(allocator: std.mem.Allocator, body: []const u8, boundary: []const u8) !FileData {
    var file_result: ?FileData = null;
    var path_result: ?[]const u8 = null;

    // Build boundary markers - RFC 2046 says boundary can have optional -- prefix in body
    const delimiter = try std.fmt.allocPrint(allocator, "--{s}", .{boundary});
    defer allocator.free(delimiter);

    var pos: usize = 0;

    while (pos < body.len) {
        // Find next boundary
        const boundary_start = std.mem.indexOfPos(u8, body, pos, delimiter) orelse break;
        const next_pos = boundary_start + delimiter.len;

        // Check for end boundary (--
        if (next_pos + 2 <= body.len and std.mem.eql(u8, body[next_pos .. next_pos + 2], "--")) {
            break;
        }

        // Skip past boundary and CRLF or LF
        var part_start = next_pos;
        if (part_start + 2 <= body.len and std.mem.eql(u8, body[part_start .. part_start + 2], "\r\n")) {
            part_start += 2;
        } else if (part_start < body.len and body[part_start] == '\n') {
            part_start += 1;
        }

        // Find end of this part (next boundary)
        const part_end = std.mem.indexOfPos(u8, body, part_start, delimiter) orelse break;
        const part = body[part_start..part_end];

        // Parse part headers and content
        if (try parsePart(allocator, part)) |file_data| {
            if (file_data.path != null) {
                // This is the path field
                if (path_result) |old_path| {
                    allocator.free(old_path);
                }
                path_result = file_data.path;
                // Don't free path when freeing file_data since we moved it
                const moved_file_data = FileData{
                    .filename = file_data.filename,
                    .content = file_data.content,
                    .path = null,
                };
                // Free the filename and content if they exist (path field doesn't have them)
                allocator.free(moved_file_data.filename);
                allocator.free(moved_file_data.content);
            } else {
                // This is the file field
                if (file_result) |old| {
                    allocator.free(old.filename);
                    allocator.free(old.content);
                }
                file_result = file_data;
            }
        } else if (try parsePathField(allocator, part)) |path| {
            if (path_result) |old_path| {
                allocator.free(old_path);
            }
            path_result = path;
        }

        pos = part_end;
    }

    if (file_result) |result| {
        return FileData{
            .filename = result.filename,
            .content = result.content,
            .path = path_result,
        };
    }

    return error.NoFileField;
}

/// Parse a single multipart part
fn parsePart(allocator: std.mem.Allocator, part: []const u8) !?FileData {
    // Find end of headers (double CRLF or double LF)
    var header_end: ?usize = std.mem.indexOf(u8, part, "\r\n\r\n");
    var header_end_offset: usize = 4;
    var line_ending_len: usize = 2;

    if (header_end == null) {
        header_end = std.mem.indexOf(u8, part, "\n\n");
        header_end_offset = 2;
        line_ending_len = 1;
    }

    const header_end_pos = header_end orelse return null;

    const headers = part[0..header_end_pos];
    var content = part[header_end_pos + header_end_offset ..];

    // Remove trailing line ending before boundary (but not if content is empty)
    if (content.len >= line_ending_len) {
        if (line_ending_len == 2 and std.mem.eql(u8, content[content.len - 2 ..], "\r\n")) {
            content = content[0 .. content.len - 2];
        } else if (content[content.len - 1] == '\n') {
            content = content[0 .. content.len - 1];
        }
    }

    // Check if this is a file upload (Content-Disposition with filename)
    // Case-insensitive search for Content-Disposition
    const disposition = findCaseInsensitive(headers, "Content-Disposition:") orelse return null;

    // Find end of disposition line
    var disp_end = std.mem.indexOfPos(u8, headers, disposition, "\r\n");
    if (disp_end == null) {
        disp_end = std.mem.indexOfPos(u8, headers, disposition, "\n");
    }
    const disp_end_pos = disp_end orelse headers.len;
    const disp_line = headers[disposition..disp_end_pos];

    // Extract filename (handle both quoted and unquoted)
    const filename = extractFilename(allocator, disp_line) orelse return null;
    defer allocator.free(filename);

    if (filename.len == 0) return null;

    // Check file size limit
    if (content.len > MAX_FILE_SIZE) {
        return error.FileTooLarge;
    }

    return FileData{
        .filename = try allocator.dupe(u8, filename),
        .content = try allocator.dupe(u8, content),
    };
}

/// Parse a path field from multipart form (name="path")
fn parsePathField(allocator: std.mem.Allocator, part: []const u8) !?[]const u8 {
    // Find end of headers (double CRLF or double LF)
    var header_end: ?usize = std.mem.indexOf(u8, part, "\r\n\r\n");
    var header_end_offset: usize = 4;

    if (header_end == null) {
        header_end = std.mem.indexOf(u8, part, "\n\n");
        header_end_offset = 2;
    }

    const header_end_pos = header_end orelse return null;

    const headers = part[0..header_end_pos];
    var content = part[header_end_pos + header_end_offset ..];

    // Remove trailing line ending before boundary
    if (content.len > 0) {
        if (std.mem.endsWith(u8, content, "\r\n")) {
            content = content[0 .. content.len - 2];
        } else if (std.mem.endsWith(u8, content, "\n")) {
            content = content[0 .. content.len - 1];
        }
    }

    // Check for Content-Disposition with name="path"
    const disposition = findCaseInsensitive(headers, "Content-Disposition:") orelse return null;

    // Find end of disposition line
    var disp_end = std.mem.indexOfPos(u8, headers, disposition, "\r\n");
    if (disp_end == null) {
        disp_end = std.mem.indexOfPos(u8, headers, disposition, "\n");
    }
    const disp_end_pos = disp_end orelse headers.len;
    const disp_line = headers[disposition..disp_end_pos];

    // Check if this is the path field (name="path")
    const name_prefix = "name=";
    const name_idx = findCaseInsensitive(disp_line, name_prefix) orelse return null;
    var name_start = name_idx + name_prefix.len;

    // Skip whitespace and quotes
    while (name_start < disp_line.len and (disp_line[name_start] == ' ' or disp_line[name_start] == '\t')) {
        name_start += 1;
    }
    if (name_start >= disp_line.len) return null;

    const is_quoted = disp_line[name_start] == '"';
    if (is_quoted) name_start += 1;

    var name_end = name_start;
    while (name_end < disp_line.len) {
        const c = disp_line[name_end];
        if (is_quoted) {
            if (c == '"') break;
        } else {
            if (c == ';' or c == ' ' or c == '\r' or c == '\n') break;
        }
        name_end += 1;
    }

    const field_name = disp_line[name_start..name_end];
    if (!std.mem.eql(u8, field_name, "path")) return null;

    // This is the path field, return the content
    if (content.len == 0) return null;
    return allocator.dupe(u8, content) catch return null;
}

/// Case-insensitive search for a substring
fn findCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            return i;
        }
    }
    return null;
}

/// Extract filename from Content-Disposition header (handles quoted and unquoted)
fn extractFilename(allocator: std.mem.Allocator, disp_line: []const u8) ?[]const u8 {
    // Look for filename= (case-insensitive)
    const filename_prefix = "filename=";
    const idx = findCaseInsensitive(disp_line, filename_prefix) orelse return null;
    var start = idx + filename_prefix.len;

    // Skip whitespace
    while (start < disp_line.len and std.ascii.isWhitespace(disp_line[start])) {
        start += 1;
    }

    if (start >= disp_line.len) return null;

    // Check if quoted
    if (disp_line[start] == '"') {
        start += 1;
        const end = std.mem.indexOfScalarPos(u8, disp_line, start, '"') orelse disp_line.len;
        return allocator.dupe(u8, disp_line[start..end]) catch return null;
    } else {
        // Unquoted filename - take until semicolon, space, or end
        var end = start;
        while (end < disp_line.len and
            disp_line[end] != ';' and
            disp_line[end] != ' ' and
            disp_line[end] != '\r' and
            disp_line[end] != '\n')
        {
            end += 1;
        }
        return allocator.dupe(u8, disp_line[start..end]) catch return null;
    }
}

/// Check if a path contains directory traversal attempts
fn containsTraversal(path: []const u8) bool {
    // Normalize backslashes to forward slashes for checking
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        const c = path[i];
        // Check for ".." as a path component (prevents /../, ../, etc.)
        if (c == '.' and i + 1 < path.len and path[i + 1] == '.') {
            // Check if it's at start or preceded by /
            const at_start = i == 0;
            const preceded_by_sep = i > 0 and (path[i - 1] == '/' or path[i - 1] == '\\');
            // Check if it's at end or followed by / or \
            const at_end = i + 2 == path.len;
            const followed_by_sep = i + 2 < path.len and (path[i + 2] == '/' or path[i + 2] == '\\');

            if ((at_start or preceded_by_sep) and (at_end or followed_by_sep)) {
                return true;
            }
        }
    }
    return false;
}

/// Ensure parent directories exist for the given path
fn ensureParentDirs(io: Io, root_dir: Io.Dir, path: []const u8) !void {
    // Find the last separator to get the directory portion
    const last_sep = std.mem.lastIndexOfAny(u8, path, "/\\");
    if (last_sep == null) return; // No directory component

    const dir_path = path[0..last_sep.?];
    if (dir_path.len == 0) return; // Root directory

    // Use createDirPath to create all parent directories at once
    root_dir.createDirPath(io, dir_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("Failed to create directories '{s}': {s}\n", .{ dir_path, @errorName(err) });
            return err;
        }
    };
}

/// Write the uploaded file to disk
fn writeUploadedFile(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    root_dir: Io.Dir,
    filename: []const u8,
    content: []const u8,
) !void {
    // Ensure parent directories exist
    ensureParentDirs(io, root_dir, filename) catch |err| {
        std.debug.print("Failed to create directories for {s}: {s}\n", .{ filename, @errorName(err) });
        return err;
    };

    // Open/create file for writing
    const file = root_dir.createFile(io, filename, .{ .truncate = true }) catch |err| {
        std.debug.print("Failed to create file {s}: {s}\n", .{ filename, @errorName(err) });
        return err;
    };
    defer file.close(io);

    // Write content using file writer
    var write_buf: [8192]u8 = undefined;
    var file_writer = file.writer(io, &write_buf);
    try file_writer.interface.writeAll(content);
    try file_writer.interface.flush();

    // Extract directory path from filename for the back link
    const dir_path = std.fs.path.dirname(filename);

    // Send success response
    const message = try std.fmt.allocPrint(allocator, "File '{s}' uploaded successfully ({d} bytes)", .{ filename, content.len });
    defer allocator.free(message);

    try sendUploadSuccess(stream, io, message, dir_path);
}

/// Send a successful upload response
fn sendUploadSuccess(stream: Io.net.Stream, io: Io, message: []const u8, dir_path: ?[]const u8) !void {
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
        \\  <title>Upload Successful</title>
        \\  <style>
        \\    body { font-family: sans-serif; margin: 2em; text-align: center; }
        \\    .success { color: #28a745; }
        \\    a { color: #0366d6; text-decoration: none; }
        \\    a:hover { text-decoration: underline; }
        \\  </style>
        \\</head><body>
        \\  <h1 class="success">✓ Upload Successful</h1>
        \\  <p>
    );
    try html.appendSlice(allocator, message);

    // Add back link - go to the directory where the file was uploaded
    if (dir_path) |path| {
        try html.appendSlice(allocator, "</p>\n  <p><a href=\"/");
        try html.appendSlice(allocator, path);
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
