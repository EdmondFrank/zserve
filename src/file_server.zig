const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const mime_types = @import("mime_types.zig");

const BUFFER_SIZE = 64 * 1024;
const MAX_PREVIEW_SIZE = 1024 * 1024; // 1MB max for preview files

/// Check if a file should be previewed (JSON, YAML, TOML, Shell)
fn isPreviewableFile(mime_type: []const u8) bool {
    return std.mem.eql(u8, mime_type, "application/json") or
        std.mem.eql(u8, mime_type, "application/yaml") or
        std.mem.eql(u8, mime_type, "application/toml") or
        std.mem.eql(u8, mime_type, "application/x-sh");
}

/// Serve a file to the client, handling range requests
pub fn serveFile(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    path: []const u8,
    root_dir: Io.Dir,
    request: []const u8,
) !void {
    const file = try root_dir.openFile(io, path, .{});
    defer file.close(io);

    const file_size = try file.length(io);
    const mime_type = mime_types.getMimeType(path);
    const filename = std.fs.path.basename(path);

    // Check if this is a previewable file (JSON/YAML/TOML) within size limit
    if (isPreviewableFile(mime_type) and file_size <= MAX_PREVIEW_SIZE) {
        servePreview(io, allocator, stream, file, mime_type, filename, file_size) catch |err| {
            std.debug.print("Error serving preview: {s}, falling back to raw file\n", .{@errorName(err)});
            try serveFullFile(io, stream, file, mime_type, filename, file_size);
        };
        return;
    }

    // Parse headers to check for Range request
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    var lines = std.mem.splitScalar(u8, request, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n");
        if (trimmed.len == 0) break;

        if (std.mem.indexOf(u8, trimmed, ": ")) |colon| {
            const key = try allocator.dupe(u8, std.mem.trim(u8, trimmed[0..colon], " "));
            const value = try allocator.dupe(u8, std.mem.trim(u8, trimmed[colon + 2 ..], " "));
            try headers.put(key, value);
        }
    }

    if (headers.get("Range")) |range_str| {
        if (http.parseRange(range_str, file_size)) |range| {
            try sendPartialContent(io, stream, file, mime_type, filename, file_size, range);
        } else |_| {
            // Invalid range, send full file
            try serveFullFile(io, stream, file, mime_type, filename, file_size);
        }
    } else {
        try serveFullFile(io, stream, file, mime_type, filename, file_size);
    }
}

/// Serve the entire file with 200 OK status
fn serveFullFile(
    io: Io,
    stream: Io.net.Stream,
    file: Io.File,
    mime_type: []const u8,
    filename: []const u8,
    file_size: u64,
) !void {
    try http.sendResponseHeaders(stream, io, .ok, &[_]struct { []const u8, []const u8 }{
        .{ "Content-Type", mime_type },
        .{ "Content-Length", try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{file_size}) },
        .{ "Accept-Ranges", "bytes" },
        .{ "Content-Disposition", try std.fmt.allocPrint(std.heap.page_allocator, "inline; filename=\"{s}\"", .{filename}) },
    });

    var write_buf: [BUFFER_SIZE]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);

    var read_buf: [BUFFER_SIZE]u8 = undefined;
    var offset: u64 = 0;
    while (offset < file_size) {
        const to_read = @min(BUFFER_SIZE, file_size - offset);
        const n = file.readPositionalAll(io, read_buf[0..to_read], offset) catch |err| {
            std.debug.print("Error reading file: {s}\n", .{@errorName(err)});
            return;
        };
        if (n == 0) break;

        try stream_writer.interface.writeAll(read_buf[0..n]);
        offset += n;
    }
    try stream_writer.interface.flush();
}

/// Serve a preview of JSON/YAML/TOML file with syntax highlighting
fn servePreview(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    file: Io.File,
    mime_type: []const u8,
    filename: []const u8,
    file_size: u64,
) !void {
    // Read file content into buffer
    const content = try allocator.alloc(u8, @as(usize, @intCast(file_size)));
    defer allocator.free(content);

    var pos: usize = 0;
    while (pos < file_size) {
        const to_read = @min(BUFFER_SIZE, file_size - pos);
        const n = file.readPositionalAll(io, content[pos..pos + to_read], pos) catch |err| {
            std.debug.print("Error reading file: {s}\n", .{@errorName(err)});
            return err;
        };
        if (n == 0) break;
        pos += n;
    }

    // Determine language for syntax highlighting
    const lang = if (std.mem.eql(u8, mime_type, "application/json"))
        "json"
    else if (std.mem.eql(u8, mime_type, "application/yaml"))
        "yaml"
    else if (std.mem.eql(u8, mime_type, "application/toml"))
        "toml"
    else if (std.mem.eql(u8, mime_type, "application/x-sh"))
        "bash"
    else
        "text";

    // Escape HTML special characters in content
    var escaped = std.ArrayList(u8).initCapacity(allocator, pos * 2) catch return error.OutOfMemory;
    defer escaped.deinit(allocator);

    for (content[0..pos]) |c| {
        switch (c) {
            '&' => try escaped.appendSlice(allocator, "&amp;"),
            '<' => try escaped.appendSlice(allocator, "&lt;"),
            '>' => try escaped.appendSlice(allocator, "&gt;"),
            '"' => try escaped.appendSlice(allocator, "&quot;"),
            '\'' => try escaped.appendSlice(allocator, "&#x27;"),
            else => try escaped.append(allocator, c),
        }
    }

    // Build HTML response - note: {{ and }} are escaped braces for Zig fmt
    const html_template =
        \\<!DOCTYPE html>
        \\<html><head>
        \\  <meta charset="utf-8">
        \\  <title>{s} - Preview</title>
        \\  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github.min.css">
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/json.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/yaml.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/ini.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/bash.min.js"></script>
        \\  <style>
        \\    body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 0; background: #f6f8fa; }}
        \\    .header {{ background: linear-gradient(135deg, #3b82f6 0%, #2563eb 100%); color: white; padding: 1em 2em; box-shadow: 0 2px 8px rgba(37,99,235,0.3); display: flex; align-items: center; justify-content: space-between; }}
        \\    .header h1 {{ margin: 0; font-size: 1.2em; font-weight: 500; }}
        \\    .header .meta {{ font-size: 0.85em; opacity: 0.9; }}
        \\    .header a {{ color: white; text-decoration: none; padding: 0.5em 1em; background: rgba(255,255,255,0.2); border-radius: 6px; transition: background 0.2s; }}
        \\    .header a:hover {{ background: rgba(255,255,255,0.3); }}
        \\    .container {{ max-width: 1200px; margin: 2em auto; padding: 0 2em; }}
        \\    .content {{ background: white; border-radius: 12px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); overflow: hidden; }}
        \\    pre {{ margin: 0; padding: 1.5em; overflow-x: auto; font-size: 14px; line-height: 1.6; }}
        \\    code {{ font-family: "SF Mono", Monaco, Inconsolata, "Fira Code", monospace; }}
        \\    .hljs {{ background: transparent; padding: 0; }}
        \\  </style>
        \\</head><body>
        \\  <div class="header">
        \\    <div>
        \\      <h1>📄 {s}</h1>
        \\      <div class="meta">{s} • {d} bytes</div>
        \\    </div>
        \\    <a href="/">← Back to directory</a>
        \\  </div>
        \\  <div class="container">
        \\    <div class="content">
        \\      <pre><code class="language-{s}">{s}</code></pre>
        \\    </div>
        \\  </div>
        \\  <script>hljs.highlightAll();</script>
        \\</body></html>
    ;

    const html = try std.fmt.allocPrint(allocator, html_template, .{
        filename, filename, mime_type, file_size, lang, escaped.items,
    });
    defer allocator.free(html);

    try http.sendResponseHeaders(stream, io, .ok, &[_]struct { []const u8, []const u8 }{
        .{ "Content-Type", "text/html; charset=utf-8" },
        .{ "Content-Length", try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{html.len}) },
    });

    var write_buf: [BUFFER_SIZE]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);
    try stream_writer.interface.writeAll(html);
    try stream_writer.interface.flush();
}

/// Send a partial file response for range requests (206 Partial Content)
fn sendPartialContent(
    io: Io,
    stream: Io.net.Stream,
    file: Io.File,
    mime_type: []const u8,
    filename: []const u8,
    file_size: u64,
    range: http.Range,
) !void {
    const end = range.end orelse (file_size - 1);
    const len = end - range.start + 1;

    try http.sendResponseHeaders(stream, io, .partial_content, &[_]struct { []const u8, []const u8 }{
        .{ "Content-Type", mime_type },
        .{ "Content-Length", try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{len}) },
        .{ "Content-Range", try std.fmt.allocPrint(std.heap.page_allocator, "bytes {d}-{d}/{d}", .{ range.start, end, file_size }) },
        .{ "Accept-Ranges", "bytes" },
        .{ "Content-Disposition", try std.fmt.allocPrint(std.heap.page_allocator, "inline; filename=\"{s}\"", .{filename}) },
    });

    var write_buf: [BUFFER_SIZE]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);

    var read_buf: [BUFFER_SIZE]u8 = undefined;
    var remaining = len;
    var offset = range.start;
    while (remaining > 0) {
        const read_size = @min(remaining, read_buf.len);
        const n = file.readPositionalAll(io, read_buf[0..read_size], offset) catch |err| {
            std.debug.print("Error reading file at offset {d}: {s}\n", .{ offset, @errorName(err) });
            return;
        };
        if (n == 0) break;

        try stream_writer.interface.writeAll(read_buf[0..n]);
        remaining -= n;
        offset += n;
    }
    try stream_writer.interface.flush();
}
