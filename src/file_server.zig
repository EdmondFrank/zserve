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
        std.mem.eql(u8, mime_type, "text/css; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-cmake; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-justfile; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-elixir; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-dart; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-erlang; charset=utf-8") or
        std.mem.eql(u8, mime_type, "application/erlang; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-haskell; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-lua; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-rsrc; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-perl; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-terraform; charset=utf-8") or
        std.mem.eql(u8, mime_type, "text/x-nginx-conf; charset=utf-8");
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

/// Get the required highlight.js script tags for a specific language.
/// Returns only the language-specific modules needed, not the core library.
fn getHighlightJsScripts(lang: []const u8) []const u8 {
    // Language dependency map:
    // - TypeScript includes JavaScript
    // - C++ depends on C
    // - SCSS/Less depend on CSS
    if (std.mem.eql(u8, lang, "json")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/json.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "yaml")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/yaml.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "toml")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/ini.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "bash")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/bash.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "markdown")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/markdown.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "javascript")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/javascript.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "typescript")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/typescript.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "python")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/python.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "ruby")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/ruby.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "go")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/go.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "rust")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/rust.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "java")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/java.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "c")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/c.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "cpp")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/c.min.js"></script>
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/cpp.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "swift")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/swift.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "kotlin")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/kotlin.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "php")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/php.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "zig")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/zig.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "css")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/css.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "scss")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/css.min.js"></script>
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/scss.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "less")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/css.min.js"></script>
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/less.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "sql")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/sql.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "graphql")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/graphql.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "xml")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/xml.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "ini")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/ini.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "dockerfile")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/dockerfile.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "makefile")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/makefile.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "cmake")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/cmake.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "elixir")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/elixir.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "dart")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/dart.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "erlang")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/erlang.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "haskell")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/haskell.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "lua")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/lua.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "r")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/r.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "perl")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/perl.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "hcl")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/terraform.min.js"></script>
    ;
    if (std.mem.eql(u8, lang, "nginx")) return
        \\<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/languages/nginx.min.js"></script>
    ;

    // Default: no additional scripts needed for plain text
    return "";
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
    else if (std.mem.eql(u8, mime_type, "text/x-cmake; charset=utf-8"))
        "cmake"
    else if (std.mem.eql(u8, mime_type, "text/x-justfile; charset=utf-8"))
        "bash"
    else if (std.mem.eql(u8, mime_type, "text/x-elixir; charset=utf-8"))
        "elixir"
    else if (std.mem.eql(u8, mime_type, "text/x-dart; charset=utf-8"))
        "dart"
    else if (std.mem.eql(u8, mime_type, "text/x-erlang; charset=utf-8") or
        std.mem.eql(u8, mime_type, "application/erlang; charset=utf-8"))
        "erlang"
    else if (std.mem.eql(u8, mime_type, "text/x-haskell; charset=utf-8"))
        "haskell"
    else if (std.mem.eql(u8, mime_type, "text/x-lua; charset=utf-8"))
        "lua"
    else if (std.mem.eql(u8, mime_type, "text/x-rsrc; charset=utf-8"))
        "r"
    else if (std.mem.eql(u8, mime_type, "text/x-perl; charset=utf-8"))
        "perl"
    else if (std.mem.eql(u8, mime_type, "text/x-terraform; charset=utf-8"))
        "hcl"
    else if (std.mem.eql(u8, mime_type, "text/x-nginx-conf; charset=utf-8"))
        "nginx"
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
    // The template uses {6s} for language-specific highlight.js scripts
    const html_template =
        \\<!DOCTYPE html>
        \\<html><head>
        \\  <meta charset="utf-8">
        \\  <title>{s} - Preview</title>
        \\  <link id="hljs-theme" rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github.min.css">
        \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
        \\  {s}
        \\  <style>
        \\    :root {{
        \\      --bg-color: #ffffff;
        \\      --text-color: #1f2937;
        \\      --text-secondary: #6b7280;
        \\      --border-color: #e5e7eb;
        \\      --header-gradient-start: #3b82f6;
        \\      --header-gradient-end: #2563eb;
        \\      --header-text: #ffffff;
        \\      --code-bg: #f6f8fa;
        \\      --code-border: #e5e7eb;
        \\      --scrollbar-thumb: #d1d5db;
        \\      --scrollbar-track: #f3f4f6;
        \\      --line-number-color: #9ca3af;
        \\      --line-number-border: #e5e7eb;
        \\    }}
        \\    body.dark-mode {{
        \\      --bg-color: #0d1117;
        \\      --text-color: #c9d1d9;
        \\      --text-secondary: #8b949e;
        \\      --border-color: #30363d;
        \\      --header-gradient-start: #3b82f6;
        \\      --header-gradient-end: #2563eb;
        \\      --header-text: #ffffff;
        \\      --code-bg: #161b22;
        \\      --code-border: #30363d;
        \\      --scrollbar-thumb: #30363d;
        \\      --scrollbar-track: #0d1117;
        \\      --line-number-color: #484f58;
        \\      --line-number-border: #30363d;
        \\    }}
        \\    * {{ box-sizing: border-box; }}
        \\    html, body {{ margin: 0; padding: 0; }}
        \\    body {{
        \\      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        \\      background-color: var(--bg-color);
        \\      color: var(--text-color);
        \\      transition: background-color 0.3s, color 0.3s;
        \\    }}
        \\    ::-webkit-scrollbar {{ width: 8px; height: 8px; }}
        \\    ::-webkit-scrollbar-track {{ background: var(--scrollbar-track); }}
        \\    ::-webkit-scrollbar-thumb {{ background: var(--scrollbar-thumb); border-radius: 4px; }}
        \\    ::-webkit-scrollbar-thumb:hover {{ background: var(--text-secondary); }}
        \\    .header {{
        \\      background: linear-gradient(135deg, var(--header-gradient-start) 0%, var(--header-gradient-end) 100%);
        \\      color: var(--header-text);
        \\      padding: 0;
        \\      box-shadow: 0 2px 8px rgba(0,0,0,0.15);
        \\      position: sticky;
        \\      top: 0;
        \\      z-index: 100;
        \\    }}
        \\    .header-content {{
        \\      max-width: 1400px;
        \\      margin: 0 auto;
        \\      padding: 16px 24px;
        \\      display: flex;
        \\      align-items: center;
        \\      justify-content: space-between;
        \\      flex-wrap: wrap;
        \\      gap: 12px;
        \\    }}
        \\    .header-left {{ display: flex; align-items: center; gap: 16px; }}
        \\    .header-title {{
        \\      font-size: 1.25rem;
        \\      font-weight: 600;
        \\      display: flex;
        \\      align-items: center;
        \\      gap: 10px;
        \\    }}
        \\    .header-title .icon {{ font-size: 1.4rem; }}
        \\    .back-btn {{
        \\      display: inline-flex;
        \\      align-items: center;
        \\      gap: 6px;
        \\      padding: 8px 16px;
        \\      background: rgba(255,255,255,0.15);
        \\      border: 1px solid rgba(255,255,255,0.25);
        \\      border-radius: 6px;
        \\      color: var(--header-text);
        \\      text-decoration: none;
        \\      font-size: 0.875rem;
        \\      font-weight: 500;
        \\      transition: all 0.2s;
        \\    }}
        \\    .back-btn:hover {{ background: rgba(255,255,255,0.25); transform: translateY(-1px); }}
        \\    .header-right {{ display: flex; align-items: center; gap: 12px; }}
        \\    .header-meta {{
        \\      font-size: 0.8125rem;
        \\      opacity: 0.9;
        \\      display: flex;
        \\      gap: 16px;
        \\    }}
        \\    .header-meta span {{ display: flex; align-items: center; gap: 4px; }}
        \\    .theme-toggle {{
        \\      padding: 8px 12px;
        \\      background: rgba(255,255,255,0.1);
        \\      border: 1px solid rgba(255,255,255,0.2);
        \\      border-radius: 6px;
        \\      color: var(--header-text);
        \\      font-size: 0.875rem;
        \\      cursor: pointer;
        \\      transition: all 0.2s;
        \\    }}
        \\    .theme-toggle:hover {{ background: rgba(255,255,255,0.2); }}
        \\    .container {{
        \\      max-width: 1400px;
        \\      margin: 0 auto;
        \\      padding: 24px;
        \\    }}
        \\    .content {{
        \\      background: var(--code-bg);
        \\      border: 1px solid var(--code-border);
        \\      border-radius: 12px;
        \\      overflow: hidden;
        \\      box-shadow: 0 1px 3px rgba(0,0,0,0.1);
        \\    }}
        \\    .code-wrapper {{
        \\      display: flex;
        \\      overflow-x: auto;
        \\    }}
        \\    .line-numbers {{
        \\      flex-shrink: 0;
        \\      padding: 1.5em 0;
        \\      padding-right: 16px;
        \\      padding-left: 16px;
        \\      text-align: right;
        \\      color: var(--line-number-color);
        \\      border-right: 1px solid var(--line-number-border);
        \\      font-family: ui-monospace, SFMono-Regular, "SF Mono", Consolas, "Liberation Mono", Menlo, monospace;
        \\      font-size: 14px;
        \\      line-height: 1.6;
        \\      user-select: none;
        \\      white-space: pre;
        \\    }}
        \\    pre {{ margin: 0; padding: 1.5em; overflow-x: auto; font-size: 14px; line-height: 1.6; flex: 1; }}
        \\    code {{ font-family: ui-monospace, SFMono-Regular, "SF Mono", Consolas, "Liberation Mono", Menlo, monospace; }}
        \\    .hljs {{ background: transparent; padding: 0; }}
        \\    @media (max-width: 640px) {{
        \\      .header-content {{ padding: 12px 16px; }}
        \\      .header-title {{ font-size: 1rem; }}
        \\      .container {{ padding: 16px; }}
        \\      .header-meta {{ display: none; }}
        \\    }}
        \\  </style>
        \\</head><body>
        \\  <header class="header">
        \\    <div class="header-content">
        \\      <div class="header-left">
        \\        <a href="/" class="back-btn">
        \\          <span>←</span> Back
        \\        </a>
        \\        <div class="header-title">
        \\          <span class="icon">📄</span>
        \\          <span>{s}</span>
        \\        </div>
        \\      </div>
        \\      <div class="header-right">
        \\        <div class="header-meta">
        \\          <span>{s}</span>
        \\          <span>{d} bytes</span>
        \\        </div>
        \\        <button class="theme-toggle" onclick="toggleTheme()" id="themeToggle">🌙 Dark</button>
        \\      </div>
        \\    </div>
        \\  </header>
        \\  <div class="container">
        \\    <div class="content">
        \\      <div class="code-wrapper">
        \\        <div class="line-numbers" id="lineNumbers"></div>
        \\        <pre><code class="language-{s}">{s}</code></pre>
        \\      </div>
        \\    </div>
        \\  </div>
        \\  <script>
        \\    // Generate line numbers
        \\    (function() {{
        \\      const code = document.querySelector('code');
        \\      const lineNumbers = document.getElementById('lineNumbers');
        \\      const lines = code.textContent.split('\n');
        \\      // Remove last empty line if present
        \\      if (lines[lines.length - 1] === '') lines.pop();
        \\      lineNumbers.textContent = lines.map((_, i) => i + 1).join('\n');
        \\    }})();
        \\    // Theme handling
        \\    function toggleTheme() {{
        \\      const isDark = document.body.classList.toggle('dark-mode');
        \\      localStorage.setItem('theme', isDark ? 'dark' : 'light');
        \\      updateThemeUI();
        \\    }}
        \\    function updateThemeUI() {{
        \\      const isDark = document.body.classList.contains('dark-mode');
        \\      const btn = document.getElementById('themeToggle');
        \\      if (btn) btn.textContent = isDark ? '☀️ Light' : '🌙 Dark';
        \\      const hljsTheme = document.getElementById('hljs-theme');
        \\      if (hljsTheme) {{
        \\        hljsTheme.href = isDark
        \\          ? 'https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github-dark.min.css'
        \\          : 'https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github.min.css';
        \\      }}
        \\    }}
        \\    function initTheme() {{
        \\      const savedTheme = localStorage.getItem('theme');
        \\      if (savedTheme === 'dark') {{
        \\        document.body.classList.add('dark-mode');
        \\      }} else if (savedTheme === 'light') {{
        \\        document.body.classList.remove('dark-mode');
        \\      }} else if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {{
        \\        document.body.classList.add('dark-mode');
        \\      }}
        \\      updateThemeUI();
        \\    }}
        \\    initTheme();
        \\    hljs.highlightAll();
        \\  </script>
        \\</body></html>
    ;

    // Get language-specific highlight.js scripts
    const hljs_scripts = getHighlightJsScripts(lang);

    const html = try std.fmt.allocPrint(allocator, html_template, .{
        filename, // {0s} - page title
        hljs_scripts, // {1s} - language-specific scripts
        filename, // {2s} - filename in header
        mime_type, // {3s} - mime type
        file_size, // {4d} - file size
        lang, // {5s} - language class
        escaped.items, // {6s} - escaped code content
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
