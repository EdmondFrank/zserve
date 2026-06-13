const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const mime_types = @import("mime_types.zig");
const markdown = @import("markdown.zig");

const BUFFER_SIZE = 64 * 1024;
const MAX_PREVIEW_SIZE = 1024 * 1024; // 1MB max for preview files

/// Check if a file should be previewed (JSON, YAML, TOML, Shell)
fn isPreviewableFile(mime_type: []const u8) bool {
    return std.mem.eql(u8, mime_type, "application/json") or
        std.mem.eql(u8, mime_type, "application/yaml") or
        std.mem.eql(u8, mime_type, "application/toml") or
        std.mem.startsWith(u8, mime_type, "application/x-sh") or
        isSourceCodeFile(mime_type);
}

/// Check if a file is a source code file that can be previewed with syntax highlighting
fn isSourceCodeFile(mime_type: []const u8) bool {
    return std.mem.eql(u8, mime_type, "application/javascript; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-typescript; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-jsx; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-python; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-ruby; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-go; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-rust; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-java; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-c; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-c++; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-swift; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-kotlin; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-php; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-zig; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-vue; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-svelte; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-scss; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-less; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-sql; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-graphql; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/xml; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-ini; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-dockerfile; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-makefile; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/css; charset=utf-8");
}

/// Check if a file is a Markdown file
fn isMarkdownFile(mime_type: []const u8) bool {
    return std.mem.startsWith(u8, mime_type, "text/markdown");
}

/// Serve a file to the client, handling range requests
pub fn serveFile(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    path: []const u8,
    root_dir: Io.Dir,
    headers: std.StringHashMap([]const u8),
) !void {
    const file = try root_dir.openFile(io, path, .{});
    defer file.close(io);

    const file_size = try file.length(io);
    const mime_type = mime_types.getMimeType(path);
    const filename = std.fs.path.basename(path);

    // Get parent directory path for "back to directory" link
    const dir_path = std.fs.path.dirname(path) orelse ".";

    // Check if this is a Markdown file within size limit
    if (isMarkdownFile(mime_type) and file_size <= MAX_PREVIEW_SIZE) {
        serveMarkdownPreview(io, allocator, stream, file, path, dir_path, file_size) catch |err| {
            std.debug.print("Error serving Markdown preview: {s}, falling back to raw file\n", .{@errorName(err)});
            try serveFullFile(io, stream, file, mime_type, filename, file_size);
        };
        return;
    }

    // Check if this is a previewable file (JSON/YAML/TOML) within size limit
    if (isPreviewableFile(mime_type) and file_size <= MAX_PREVIEW_SIZE) {
        servePreview(io, allocator, stream, file, mime_type, filename, file_size) catch |err| {
            std.debug.print("Error serving preview: {s}, falling back to raw file\n", .{@errorName(err)});
            try serveFullFile(io, stream, file, mime_type, filename, file_size);
        };
        return;
    }

    // Use pre-parsed headers from handler to check for Range request
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
    var len_buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{file_size}) catch unreachable;
    var disp_buf: [1024]u8 = undefined;
    const disp_str = try std.fmt.bufPrint(&disp_buf, "inline; filename=\"{s}\"", .{filename});
    try http.sendResponseHeaders(stream, io, .ok, &[_]struct { []const u8, []const u8 }{
        .{ "Content-Type", mime_type },
        .{ "Content-Length", len_str },
        .{ "Accept-Ranges", "bytes" },
        .{ "Content-Disposition", disp_str },
    });

    var write_buf: [BUFFER_SIZE]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);

    var read_buf: [BUFFER_SIZE]u8 = undefined;
    var offset: u64 = 0;
    while (offset < file_size) {
        const to_read = @min(BUFFER_SIZE, file_size - offset);
        const n = file.readPositionalAll(io, read_buf[0..to_read], offset) catch |err| {
            std.debug.print("Error reading file: {s}\n", .{@errorName(err)});
            return err;
        };
        if (n == 0) break;

        try stream_writer.interface.writeAll(read_buf[0..n]);
        offset += n;
    }
    try stream_writer.interface.flush();
}

/// Serve a Markdown file with the enhanced Markdown preview
fn serveMarkdownPreview(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    file: Io.File,
    file_path: []const u8,
    dir_path: []const u8,
    file_size: u64,
) !void {
    // Read file content into buffer
    const content = try allocator.alloc(u8, @as(usize, @intCast(file_size)));
    defer allocator.free(content);

    var pos: usize = 0;
    while (pos < file_size) {
        const to_read = @min(BUFFER_SIZE, file_size - pos);
        const n = file.readPositionalAll(io, content[pos .. pos + to_read], pos) catch |err| {
            std.debug.print("Error reading file: {s}\n", .{@errorName(err)});
            return err;
        };
        if (n == 0) break;
        pos += n;
    }

    // Use the markdown module to render the preview
    try markdown.renderMarkdownPreview(
        io,
        allocator,
        stream,
        file_path,
        dir_path,
        content[0..pos],
        file_size,
    );
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
        const n = file.readPositionalAll(io, content[pos .. pos + to_read], pos) catch |err| {
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
    else if (std.mem.startsWith(u8, mime_type, "application/x-sh"))
        "bash"
    else if (std.mem.startsWith(u8, mime_type, "text/markdown"))
        "markdown"
    else if (std.mem.eql(u8, mime_type, "application/javascript; charset=utf-8"))
        "javascript"
    else if (std.mem.eql(u8, mime_type, "text/x-typescript; charset=utf-8"))
        "typescript"
    else if (std.mem.eql(u8, mime_type, "text/x-jsx; charset=utf-8"))
        "javascript"
    else if (std.mem.eql(u8, mime_type, "text/x-python; charset=utf-8"))
        "python"
    else if (std.mem.eql(u8, mime_type, "text/x-ruby; charset=utf-8"))
        "ruby"
    else if (std.mem.eql(u8, mime_type, "text/x-go; charset=utf-8"))
        "go"
    else if (std.mem.eql(u8, mime_type, "text/x-rust; charset=utf-8"))
        "rust"
    else if (std.mem.eql(u8, mime_type, "text/x-java; charset=utf-8"))
        "java"
    else if (std.mem.eql(u8, mime_type, "text/x-c; charset=utf-8"))
        "c"
    else if (std.mem.eql(u8, mime_type, "text/x-c++; charset=utf-8"))
        "cpp"
    else if (std.mem.eql(u8, mime_type, "text/x-swift; charset=utf-8"))
        "swift"
    else if (std.mem.eql(u8, mime_type, "text/x-kotlin; charset=utf-8"))
        "kotlin"
    else if (std.mem.eql(u8, mime_type, "text/x-php; charset=utf-8"))
        "php"
    else if (std.mem.eql(u8, mime_type, "text/x-zig; charset=utf-8"))
        "zig"
    else if (std.mem.eql(u8, mime_type, "text/x-vue; charset=utf-8"))
        "xml"
    else if (std.mem.eql(u8, mime_type, "text/x-svelte; charset=utf-8"))
        "xml"
    else if (std.mem.eql(u8, mime_type, "text/css; charset=utf-8"))
        "css"
    else if (std.mem.eql(u8, mime_type, "text/x-scss; charset=utf-8"))
        "scss"
    else if (std.mem.eql(u8, mime_type, "text/x-less; charset=utf-8"))
        "less"
    else if (std.mem.eql(u8, mime_type, "text/x-sql; charset=utf-8"))
        "sql"
    else if (std.mem.eql(u8, mime_type, "text/x-graphql; charset=utf-8"))
        "graphql"
    else if (std.mem.eql(u8, mime_type, "text/xml; charset=utf-8"))
        "xml"
    else if (std.mem.eql(u8, mime_type, "text/x-ini; charset=utf-8"))
        "ini"
    else if (std.mem.eql(u8, mime_type, "text/x-dockerfile; charset=utf-8"))
        "dockerfile"
    else if (std.mem.eql(u8, mime_type, "text/x-makefile; charset=utf-8"))
        "makefile"
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
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/markdown.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/typescript.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/python.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/ruby.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/go.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/rust.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/java.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/c.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/cpp.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/swift.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/kotlin.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/php.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/zig.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/css.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/scss.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/less.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/sql.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/graphql.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/xml.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/dockerfile.min.js"></script>
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/makefile.min.js"></script>
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

    var len_buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{html.len}) catch unreachable;
    try http.sendResponseHeaders(stream, io, .ok, &[_]struct { []const u8, []const u8 }{
        .{ "Content-Type", "text/html; charset=utf-8" },
        .{ "Content-Length", len_str },
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
    const validated_end = @min(end, file_size - 1);
    const len = validated_end - range.start + 1;

    var len_buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{len}) catch unreachable;
    var range_buf: [72]u8 = undefined;
    const range_str = try std.fmt.bufPrint(&range_buf, "bytes {d}-{d}/{d}", .{ range.start, validated_end, file_size });
    var disp_buf: [1024]u8 = undefined;
    const disp_str = try std.fmt.bufPrint(&disp_buf, "inline; filename=\"{s}\"", .{filename});
    try http.sendResponseHeaders(stream, io, .partial_content, &[_]struct { []const u8, []const u8 }{
        .{ "Content-Type", mime_type },
        .{ "Content-Length", len_str },
        .{ "Content-Range", range_str },
        .{ "Accept-Ranges", "bytes" },
        .{ "Content-Disposition", disp_str },
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
            return err;
        };
        if (n == 0) break;

        try stream_writer.interface.writeAll(read_buf[0..n]);
        remaining -= n;
        offset += n;
    }
    try stream_writer.interface.flush();
}

/// Serve a file as a download with Content-Disposition: attachment
pub fn serveDownload(
    io: Io,
    stream: Io.net.Stream,
    path: []const u8,
    root_dir: Io.Dir,
) !void {
    const file = try root_dir.openFile(io, path, .{});
    defer file.close(io);

    const file_size = try file.length(io);
    const mime_type = mime_types.getMimeType(path);
    const filename = std.fs.path.basename(path);

    var len_buf: [32]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{file_size}) catch unreachable;
    var disp_buf: [1024]u8 = undefined;
    const disp_str = try std.fmt.bufPrint(&disp_buf, "attachment; filename=\"{s}\"", .{filename});

    try http.sendResponseHeaders(stream, io, .ok, &[_]struct { []const u8, []const u8 }{
        .{ "Content-Type", mime_type },
        .{ "Content-Length", len_str },
        .{ "Accept-Ranges", "bytes" },
        .{ "Content-Disposition", disp_str },
        .{ "Cache-Control", "no-cache" },
    });

    var write_buf: [BUFFER_SIZE]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buf);

    var read_buf: [BUFFER_SIZE]u8 = undefined;
    var offset: u64 = 0;
    while (offset < file_size) {
        const to_read = @min(BUFFER_SIZE, file_size - offset);
        const n = file.readPositionalAll(io, read_buf[0..to_read], offset) catch |err| {
            std.debug.print("Error reading file: {s}\n", .{@errorName(err)});
            return err;
        };
        if (n == 0) break;

        try stream_writer.interface.writeAll(read_buf[0..n]);
        offset += n;
    }
    try stream_writer.interface.flush();
}
