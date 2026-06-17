const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const zpdf = @import("zpdf");

const MAX_PDF_SIZE: usize = 50 * 1024 * 1024; // 50MB
const MAX_PAGES_EXTRACT: usize = 200;

/// Check if a MIME type represents a PDF file
pub fn isPdfFile(mime_type: []const u8) bool {
    return std.mem.eql(u8, mime_type, "application/pdf");
}

/// Render a PDF file preview using zpdf text extraction
pub fn renderPdfPreview(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    file: Io.File,
    file_path: []const u8,
    dir_path: []const u8,
    file_size: u64,
) !void {
    _ = MAX_PDF_SIZE;

    // Read the entire PDF into memory
    const pdf_bytes = try allocator.alloc(u8, @intCast(file_size));
    defer allocator.free(pdf_bytes);

    var pos: usize = 0;
    while (pos < file_size) {
        const n = file.readPositionalAll(io, pdf_bytes[pos..], pos) catch break;
        if (n == 0) break;
        pos += n;
    }

    // Open PDF with zpdf
    var doc = zpdf.Document.openFromMemory(allocator, pdf_bytes[0..pos], .permissive()) catch {
        try renderPdfFallback(io, allocator, stream, file_path, dir_path, file_size, "Failed to parse PDF document");
        return;
    };
    defer doc.close();

    // Extract markdown from all pages (limited)
    const page_count = doc.pageCount();
    const pages_to_extract = @min(page_count, MAX_PAGES_EXTRACT);

    var md_buf: std.ArrayList(u8) = .empty;
    defer md_buf.deinit(allocator);
    try md_buf.ensureTotalCapacity(allocator, pages_to_extract * @as(usize, 4096));

    for (0..pages_to_extract) |i| {
        if (i > 0) {
            md_buf.appendSlice(allocator, "\n---\n\n") catch continue;
        }
        const page_md = doc.extractMarkdown(i, allocator) catch continue;
        defer allocator.free(page_md);
        md_buf.appendSlice(allocator, page_md) catch continue;
    }

    // Get metadata
    const meta = doc.metadata();
    const title = meta.title orelse std.fs.path.basename(file_path);
    const author = meta.author orelse "Unknown";

    // Escape markdown for JavaScript embedding
    const escaped_md = try escapeForJs(allocator, md_buf.items);
    defer allocator.free(escaped_md);

    // Escape for HTML source view
    const html_escaped_md = try escapeForHtml(allocator, md_buf.items);
    defer allocator.free(html_escaped_md);

    // Build sidebar info
    const filename = std.fs.path.basename(file_path);
    const parent_dir = buildParentDir(allocator, dir_path);
    defer if (parent_dir.len > 1 and !std.mem.startsWith(u8, dir_path, "/")) allocator.free(parent_dir);

    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, file_size);

    var pages_buf: [16]u8 = undefined;
    const pages_str = std.fmt.bufPrint(&pages_buf, "{d}", .{page_count}) catch "?";

    // Build outline HTML from zpdf outline
    const outline_html = buildOutlineHtml(allocator, doc) catch "";
    defer if (outline_html.len > 0) allocator.free(outline_html);

    // Render the HTML
    var write_buf: [65536]u8 = undefined;
    var writer = stream.writer(io, &write_buf);

    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n");

    const html = try std.fmt.allocPrint(allocator, pdf_preview_template, .{
        filename, // {0s} - page title
        parent_dir, // {1s} - parent dir link
        filename, // {2s} - filename in header
        size_str, // {3s} - file size
        pages_str, // {4s} - page count
        title, // {5s} - document title
        author, // {6s} - document author
        outline_html, // {7s} - outline HTML
        escaped_md, // {8s} - markdown content for rendering
        html_escaped_md, // {9s} - markdown content for source view
    });
    defer allocator.free(html);

    try writer.interface.writeAll(html);
    try writer.interface.flush();
}

/// Build HTML for the document outline/TOC sidebar
fn buildOutlineHtml(allocator: std.mem.Allocator, doc: *zpdf.Document) ![]const u8 {
    const outline = doc.getOutline(allocator) catch return "";
    defer {
        for (outline) |item| {
            if (item.title.len > 0) allocator.free(@constCast(item.title));
        }
        allocator.free(outline);
    }

    if (outline.len == 0) return "";

    var html: std.ArrayList(u8) = .empty;
    errdefer html.deinit(allocator);
    try html.ensureTotalCapacity(allocator, 2048);

    for (outline) |item| {
        const clamped_level: usize = if (item.level > 5) 5 else item.level;
        const indent: usize = clamped_level * 12;
        const title_escaped = try escapeForHtml(allocator, item.title);
        defer allocator.free(title_escaped);

        const page_val = item.page orelse 0;
        const item_html = try std.fmt.allocPrint(allocator, "<div class=\"outline-item\" style=\"padding-left:{d}px\" data-page=\"{d}\"><a href=\"#page-{d}\">{s}</a></div>\n", .{ indent, page_val, page_val, title_escaped });
        defer allocator.free(item_html);
        try html.appendSlice(allocator, item_html);
    }

    return html.toOwnedSlice(allocator);
}

/// Render a fallback error page for PDFs that can't be parsed
fn renderPdfFallback(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    file_path: []const u8,
    dir_path: []const u8,
    file_size: u64,
    error_msg: []const u8,
) !void {
    const filename = std.fs.path.basename(file_path);
    const parent_dir = buildParentDir(allocator, dir_path);
    defer if (parent_dir.len > 1 and !std.mem.startsWith(u8, dir_path, "/")) allocator.free(parent_dir);

    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, file_size);

    var write_buf: [65536]u8 = undefined;
    var writer = stream.writer(io, &write_buf);

    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n");

    const html = try std.fmt.allocPrint(allocator, pdf_fallback_template, .{
        filename, parent_dir, filename, size_str, error_msg, file_path,
    });
    defer allocator.free(html);

    try writer.interface.writeAll(html);
    try writer.interface.flush();
}

fn buildParentDir(allocator: std.mem.Allocator, dir_path: []const u8) []const u8 {
    if (std.mem.eql(u8, dir_path, ".") or dir_path.len == 0) return "/";
    if (std.mem.startsWith(u8, dir_path, "/")) return dir_path;
    const with_slash = allocator.alloc(u8, dir_path.len + 1) catch return "/";
    with_slash[0] = '/';
    @memcpy(with_slash[1..], dir_path);
    return with_slash;
}

fn formatSize(buf: []u8, size: u64) []const u8 {
    if (size < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{size}) catch "0 B";
    } else if (size < 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{@as(f64, @floatFromInt(size)) / 1024}) catch "0 KB";
    } else if (size < 1024 * 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{@as(f64, @floatFromInt(size)) / (1024 * 1024)}) catch "0 MB";
    } else {
        return std.fmt.bufPrint(buf, "{d:.1} GB", .{@as(f64, @floatFromInt(size)) / (1024 * 1024 * 1024)}) catch "0 GB";
    }
}

fn escapeForJs(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var escape_count: usize = 0;
    for (input) |c| {
        switch (c) {
            '\\', '"', '\n', '\r', '\t', '`', '$' => escape_count += 1,
            else => {},
        }
    }
    if (escape_count == 0) return @constCast(input);

    const result = try allocator.alloc(u8, input.len + escape_count);
    var i: usize = 0;
    for (input) |c| {
        switch (c) {
            '\\' => { result[i] = '\\'; result[i + 1] = '\\'; i += 2; },
            '"' => { result[i] = '\\'; result[i + 1] = '"'; i += 2; },
            '\n' => { result[i] = '\\'; result[i + 1] = 'n'; i += 2; },
            '\r' => { result[i] = '\\'; result[i + 1] = 'r'; i += 2; },
            '\t' => { result[i] = '\\'; result[i + 1] = 't'; i += 2; },
            '`' => { result[i] = '\\'; result[i + 1] = '`'; i += 2; },
            '$' => { result[i] = '\\'; result[i + 1] = '$'; i += 2; },
            else => { result[i] = c; i += 1; },
        }
    }
    return result;
}

fn escapeForHtml(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var escape_count: usize = 0;
    for (input) |c| {
        switch (c) {
            '&' => escape_count += 4,
            '<' => escape_count += 3,
            '>' => escape_count += 3,
            '"' => escape_count += 5,
            '\'' => escape_count += 5,
            else => {},
        }
    }
    if (escape_count == 0) return @constCast(input);

    const result = try allocator.alloc(u8, input.len + escape_count);
    var i: usize = 0;
    for (input) |c| {
        switch (c) {
            '&' => { @memcpy(result[i .. i + 5], "&amp;"); i += 5; },
            '<' => { @memcpy(result[i .. i + 4], "&lt;"); i += 4; },
            '>' => { @memcpy(result[i .. i + 4], "&gt;"); i += 4; },
            '"' => { @memcpy(result[i .. i + 6], "&quot;"); i += 6; },
            '\'' => { @memcpy(result[i .. i + 6], "&#x27;"); i += 6; },
            else => { result[i] = c; i += 1; },
        }
    }
    return result;
}

const pdf_preview_template =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\  <meta name="color-scheme" content="light dark">
    \\  <title>{0s} - PDF Preview</title>
    \\  <!-- Marked.js for Markdown rendering -->
    \\  <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
    \\  <!-- Highlight.js for syntax highlighting -->
    \\  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github.min.css" id="hljs-theme">
    \\  <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
    \\  <style>
    \\    :root {{
    \\      --bg-color: #ffffff;
    \\      --text-color: #24292e;
    \\      --text-secondary: #666;
    \\      --border-color: #e2e8f0;
    \\      --link-color: #0366d6;
    \\      --hover-bg: #e5e7eb;
    \\      --header-gradient-start: #dc2626;
    \\      --header-gradient-end: #b91c1c;
    \\      --header-text: #ffffff;
    \\      --sidebar-bg: #f8fafc;
    \\      --sidebar-border: #e2e8f0;
    \\      --toc-link-color: #475569;
    \\      --toc-link-hover: #1e293b;
    \\      --toc-active-bg: #fef2f2;
    \\      --toc-active-border: #dc2626;
    \\      --code-bg: #f6f8fa;
    \\      --code-border: #d0d7de;
    \\      --blockquote-border: #d0d7de;
    \\      --blockquote-bg: #f6f8fa;
    \\      --table-border: #d0d7de;
    \\      --table-header-bg: #f6f8fa;
    \\      --table-row-alt: #f6f8fa;
    \\      --hr-color: #d0d7de;
    \\      --meta-bg: #f8fafc;
    \\      --source-bg: #f6f8fa;
    \\      --scrollbar-thumb: #cbd5e1;
    \\      --scrollbar-track: #f1f5f9;
    \\    }}
    \\    @media (prefers-color-scheme: dark) {{
    \\      :root {{
    \\        --bg-color: #0d1117;
    \\        --text-color: #c9d1d9;
    \\        --text-secondary: #8b949e;
    \\        --border-color: #30363d;
    \\        --link-color: #58a6ff;
    \\        --hover-bg: #21262d;
    \\        --header-gradient-start: #dc2626;
    \\        --header-gradient-end: #b91c1c;
    \\        --header-text: #ffffff;
    \\        --sidebar-bg: #161b22;
    \\        --sidebar-border: #30363d;
    \\        --toc-link-color: #8b949e;
    \\        --toc-link-hover: #c9d1d9;
    \\        --toc-active-bg: #1f1315;
    \\        --toc-active-border: #dc2626;
    \\        --code-bg: #161b22;
    \\        --code-border: #30363d;
    \\        --blockquote-border: #30363d;
    \\        --blockquote-bg: #161b22;
    \\        --table-border: #30363d;
    \\        --table-header-bg: #161b22;
    \\        --table-row-alt: #0d1117;
    \\        --hr-color: #30363d;
    \\        --meta-bg: #161b22;
    \\        --source-bg: #161b22;
    \\        --scrollbar-thumb: #30363d;
    \\        --scrollbar-track: #0d1117;
    \\      }}
    \\    }}
    \\    body.dark-mode {{
    \\      --bg-color: #0d1117;
    \\      --text-color: #c9d1d9;
    \\      --text-secondary: #8b949e;
    \\      --border-color: #30363d;
    \\      --link-color: #58a6ff;
    \\      --hover-bg: #21262d;
    \\      --header-gradient-start: #dc2626;
    \\      --header-gradient-end: #b91c1c;
    \\      --header-text: #ffffff;
    \\      --sidebar-bg: #161b22;
    \\      --sidebar-border: #30363d;
    \\      --toc-link-color: #8b949e;
    \\      --toc-link-hover: #c9d1d9;
    \\      --toc-active-bg: #1f1315;
    \\      --toc-active-border: #dc2626;
    \\      --code-bg: #161b22;
    \\      --code-border: #30363d;
    \\      --blockquote-border: #30363d;
    \\      --blockquote-bg: #161b22;
    \\      --table-border: #30363d;
    \\      --table-header-bg: #161b22;
    \\      --table-row-alt: #0d1117;
    \\      --hr-color: #30363d;
    \\      --meta-bg: #161b22;
    \\      --source-bg: #161b22;
    \\      --scrollbar-thumb: #30363d;
    \\      --scrollbar-track: #0d1117;
    \\    }}
    \\    * {{ box-sizing: border-box; }}
    \\    html, body {{ margin: 0; padding: 0; }}
    \\    body {{
    \\      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif;
    \\      background-color: var(--bg-color);
    \\      color: var(--text-color);
    \\      line-height: 1.6;
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
    \\    .view-toggle {{
    \\      display: flex;
    \\      background: rgba(255,255,255,0.1);
    \\      border-radius: 8px;
    \\      padding: 3px;
    \\    }}
    \\    .view-toggle button {{
    \\      padding: 8px 16px;
    \\      border: none;
    \\      background: transparent;
    \\      color: rgba(255,255,255,0.8);
    \\      font-size: 0.875rem;
    \\      font-weight: 500;
    \\      cursor: pointer;
    \\      border-radius: 6px;
    \\      transition: all 0.2s;
    \\      display: flex;
    \\      align-items: center;
    \\      gap: 6px;
    \\    }}
    \\    .view-toggle button:hover {{ color: var(--header-text); }}
    \\    .view-toggle button.active {{
    \\      background: rgba(255,255,255,0.2);
    \\      color: var(--header-text);
    \\    }}
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
    \\      display: flex;
    \\      min-height: calc(100vh - 64px);
    \\    }}
    \\    .sidebar {{
    \\      width: 300px;
    \\      flex-shrink: 0;
    \\      background: var(--sidebar-bg);
    \\      border-right: 1px solid var(--sidebar-border);
    \\      padding: 20px;
    \\      overflow-y: auto;
    \\      max-height: calc(100vh - 64px);
    \\      position: sticky;
    \\      top: 64px;
    \\    }}
    \\    .sidebar-section {{ margin-bottom: 24px; }}
    \\    .sidebar-title {{
    \\      font-size: 0.75rem;
    \\      font-weight: 600;
    \\      text-transform: uppercase;
    \\      letter-spacing: 0.05em;
    \\      color: var(--text-secondary);
    \\      margin-bottom: 12px;
    \\      padding-bottom: 8px;
    \\      border-bottom: 1px solid var(--sidebar-border);
    \\    }}
    \\    .file-meta {{
    \\      background: var(--meta-bg);
    \\      border-radius: 8px;
    \\      padding: 12px;
    \\      font-size: 0.8125rem;
    \\    }}
    \\    .file-meta-item {{
    \\      display: flex;
    \\      justify-content: space-between;
    \\      padding: 4px 0;
    \\      border-bottom: 1px solid var(--sidebar-border);
    \\    }}
    \\    .file-meta-item:last-child {{ border-bottom: none; }}
    \\    .file-meta-label {{ color: var(--text-secondary); }}
    \\    .file-meta-value {{ font-weight: 500; color: var(--text-color); }}
    \\    .outline-item {{
    \\      padding: 4px 0;
    \\      font-size: 0.8125rem;
    \\    }}
    \\    .outline-item a {{
    \\      color: var(--toc-link-color);
    \\      text-decoration: none;
    \\      transition: color 0.2s;
    \\      display: block;
    \\      white-space: nowrap;
    \\      overflow: hidden;
    \\      text-overflow: ellipsis;
    \\    }}
    \\    .outline-item a:hover {{
    \\      color: var(--toc-link-hover);
    \\    }}
    \\    .outline-list {{
    \\      max-height: 400px;
    \\      overflow-y: auto;
    \\    }}
    \\    .main {{
    \\      flex: 1;
    \\      padding: 32px 40px;
    \\      max-width: 900px;
    \\    }}
    \\    .markdown-body {{
    \\      font-size: 16px;
    \\      line-height: 1.6;
    \\      color: var(--text-color);
    \\    }}
    \\    .markdown-body > *:first-child {{ margin-top: 0 !important; }}
    \\    .markdown-body h1, .markdown-body h2, .markdown-body h3,
    \\    .markdown-body h4, .markdown-body h5, .markdown-body h6 {{
    \\      margin-top: 32px;
    \\      margin-bottom: 16px;
    \\      font-weight: 600;
    \\      line-height: 1.25;
    \\      color: var(--text-color);
    \\      scroll-margin-top: 80px;
    \\    }}
    \\    .markdown-body h1 {{
    \\      font-size: 2em;
    \\      padding-bottom: 0.3em;
    \\      border-bottom: 1px solid var(--hr-color);
    \\    }}
    \\    .markdown-body h2 {{
    \\      font-size: 1.5em;
    \\      padding-bottom: 0.3em;
    \\      border-bottom: 1px solid var(--hr-color);
    \\    }}
    \\    .markdown-body h3 {{ font-size: 1.25em; }}
    \\    .markdown-body h4 {{ font-size: 1em; }}
    \\    .markdown-body p {{ margin-bottom: 16px; }}
    \\    .markdown-body a {{ color: var(--link-color); text-decoration: none; }}
    \\    .markdown-body a:hover {{ text-decoration: underline; }}
    \\    .markdown-body strong {{ font-weight: 600; }}
    \\    .markdown-body em {{ font-style: italic; }}
    \\    .markdown-body ul, .markdown-body ol {{
    \\      margin-bottom: 16px;
    \\      padding-left: 2em;
    \\    }}
    \\    .markdown-body ul {{ list-style-type: disc; }}
    \\    .markdown-body ol {{ list-style-type: decimal; }}
    \\    .markdown-body li {{ margin: 0.25em 0; }}
    \\    .markdown-body code {{
    \\      font-family: ui-monospace, SFMono-Regular, "SF Mono", Consolas, "Liberation Mono", Menlo, monospace;
    \\      font-size: 0.875em;
    \\      padding: 0.2em 0.4em;
    \\      background: var(--code-bg);
    \\      border: 1px solid var(--code-border);
    \\      border-radius: 6px;
    \\      color: var(--text-color);
    \\    }}
    \\    .markdown-body pre {{
    \\      margin-bottom: 16px;
    \\      padding: 16px;
    \\      overflow: auto;
    \\      font-size: 85%;
    \\      line-height: 1.45;
    \\      background: var(--code-bg);
    \\      border: 1px solid var(--code-border);
    \\      border-radius: 8px;
    \\    }}
    \\    .markdown-body pre code {{
    \\      display: block;
    \\      padding: 0;
    \\      margin: 0;
    \\      overflow: visible;
    \\      line-height: inherit;
    \\      word-wrap: normal;
    \\      background: transparent;
    \\      border: 0;
    \\      font-size: 100%;
    \\    }}
    \\    .markdown-body blockquote {{
    \\      margin: 0 0 16px;
    \\      padding: 12px 16px;
    \\      color: var(--text-secondary);
    \\      border-left: 0.25em solid var(--blockquote-border);
    \\      background: var(--blockquote-bg);
    \\      border-radius: 0 6px 6px 0;
    \\    }}
    \\    .markdown-body table {{
    \\      display: block;
    \\      width: max-content;
    \\      max-width: 100%;
    \\      overflow: auto;
    \\      border-spacing: 0;
    \\      border-collapse: collapse;
    \\      margin-bottom: 16px;
    \\    }}
    \\    .markdown-body table th, .markdown-body table td {{
    \\      padding: 8px 12px;
    \\      border: 1px solid var(--table-border);
    \\      text-align: left;
    \\    }}
    \\    .markdown-body table th {{
    \\      font-weight: 600;
    \\      background: var(--table-header-bg);
    \\    }}
    \\    .markdown-body table tr:nth-child(2n) {{ background: var(--table-row-alt); }}
    \\    .markdown-body hr {{
    \\      height: 0.25em;
    \\      padding: 0;
    \\      margin: 24px 0;
    \\      background-color: var(--hr-color);
    \\      border: 0;
    \\      border-radius: 2px;
    \\    }}
    \\    .source-view {{
    \\      display: none;
    \\      background: var(--source-bg);
    \\      border: 1px solid var(--border-color);
    \\      border-radius: 8px;
    \\      padding: 20px;
    \\      overflow-x: auto;
    \\    }}
    \\    .source-view pre {{
    \\      margin: 0;
    \\      font-family: ui-monospace, SFMono-Regular, "SF Mono", Consolas, "Liberation Mono", Menlo, monospace;
    \\      font-size: 14px;
    \\      line-height: 1.6;
    \\      white-space: pre;
    \\      word-wrap: normal;
    \\    }}
    \\    .source-view pre code {{
    \\      display: block;
    \\      background: transparent;
    \\      border: none;
    \\      padding: 0;
    \\    }}
    \\    .source-view.active {{ display: block; }}
    \\    .markdown-body.hidden {{ display: none; }}
    \\    .sidebar-toggle {{
    \\      display: none;
    \\      position: fixed;
    \\      bottom: 20px;
    \\      right: 20px;
    \\      width: 50px;
    \\      height: 50px;
    \\      border-radius: 50%;
    \\      background: var(--header-gradient-start);
    \\      border: none;
    \\      color: white;
    \\      font-size: 20px;
    \\      cursor: pointer;
    \\      box-shadow: 0 4px 12px rgba(0,0,0,0.3);
    \\      z-index: 200;
    \\      transition: transform 0.2s;
    \\    }}
    \\    .sidebar-toggle:hover {{ transform: scale(1.1); }}
    \\    .pdf-badge {{
    \\      display: inline-block;
    \\      padding: 2px 8px;
    \\      background: rgba(255,255,255,0.15);
    \\      border-radius: 4px;
    \\      font-size: 0.75rem;
    \\      font-weight: 600;
    \\      letter-spacing: 0.05em;
    \\    }}
    \\    @media (max-width: 1024px) {{
    \\      .sidebar {{
    \\        position: fixed;
    \\        left: -320px;
    \\        top: 64px;
    \\        height: calc(100vh - 64px);
    \\        z-index: 99;
    \\        transition: left 0.3s ease;
    \\        box-shadow: 2px 0 8px rgba(0,0,0,0.1);
    \\        width: 300px;
    \\      }}
    \\      .sidebar.open {{ left: 0; }}
    \\      .main {{
    \\        padding: 24px;
    \\        max-width: 100%;
    \\      }}
    \\      .sidebar-toggle {{ display: flex; align-items: center; justify-content: center; }}
    \\      .overlay {{
    \\        display: none;
    \\        position: fixed;
    \\        top: 64px;
    \\        left: 0;
    \\        right: 0;
    \\        bottom: 0;
    \\        background: rgba(0,0,0,0.5);
    \\        z-index: 98;
    \\      }}
    \\      .overlay.show {{ display: block; }}
    \\    }}
    \\    @media (max-width: 640px) {{
    \\      .header-content {{ padding: 12px 16px; }}
    \\      .header-title {{ font-size: 1rem; }}
    \\      .view-toggle button {{
    \\        padding: 6px 12px;
    \\        font-size: 0.8125rem;
    \\      }}
    \\      .main {{ padding: 16px; }}
    \\    }}
    \\  </style>
    \\</head>
    \\<body>
    \\  <header class="header">
    \\    <div class="header-content">
    \\      <div class="header-left">
    \\        <a href="{1s}" class="back-btn">
    \\          <span>&larr;</span> Back to directory
    \\        </a>
    \\        <div class="header-title">
    \\          <span class="icon">&#x1F4D5;</span>
    \\          <span>{2s}</span>
    \\          <span class="pdf-badge">PDF</span>
    \\        </div>
    \\      </div>
    \\      <div class="header-right">
    \\        <div class="view-toggle">
    \\          <button id="viewRendered" class="active" onclick="switchView('rendered')">
    \\            <span>&#x1F441;</span> Rendered
    \\          </button>
    \\          <button id="viewSource" onclick="switchView('source')">
    \\            <span>&#x1F4C4;</span> Source
    \\          </button>
    \\        </div>
    \\        <button class="theme-toggle" onclick="toggleTheme()" id="themeToggle">&#x1F319; Dark</button>
    \\      </div>
    \\    </div>
    \\  </header>
    \\  <div class="overlay" id="overlay" onclick="toggleSidebar()"></div>
    \\  <div class="container">
    \\    <aside class="sidebar" id="sidebar">
    \\      <div class="sidebar-section">
    \\        <div class="sidebar-title">Document Info</div>
    \\        <div class="file-meta">
    \\          <div class="file-meta-item">
    \\            <span class="file-meta-label">Title</span>
    \\            <span class="file-meta-value">{5s}</span>
    \\          </div>
    \\          <div class="file-meta-item">
    \\            <span class="file-meta-label">Author</span>
    \\            <span class="file-meta-value">{6s}</span>
    \\          </div>
    \\          <div class="file-meta-item">
    \\            <span class="file-meta-label">Pages</span>
    \\            <span class="file-meta-value">{4s}</span>
    \\          </div>
    \\          <div class="file-meta-item">
    \\            <span class="file-meta-label">Size</span>
    \\            <span class="file-meta-value">{3s}</span>
    \\          </div>
    \\          <div class="file-meta-item">
    \\            <span class="file-meta-label">Type</span>
    \\            <span class="file-meta-value">application/pdf</span>
    \\          </div>
    \\        </div>
    \\      </div>
    \\      {7s}
    \\    </aside>
    \\    <main class="main">
    \\      <div id="renderedView" class="markdown-body"></div>
    \\      <div id="sourceView" class="source-view"><pre><code>{9s}</code></pre></div>
    \\    </main>
    \\  </div>
    \\  <button class="sidebar-toggle" onclick="toggleSidebar()" title="Toggle Sidebar">&#x1F4D6;</button>
    \\  <script>
    \\    (function() {{
    \\      // Raw markdown content from server (extracted from PDF)
    \\      const rawMarkdown = `{8s}`;
    \\      
    \\      // Configure marked.js
    \\      marked.setOptions({{
    \\        gfm: true,
    \\        breaks: false,
    \\        pedantic: false,
    \\        smartLists: true,
    \\        smartypants: true,
    \\        xhtml: false,
    \\        headerIds: true,
    \\        headerPrefix: '',
    \\        mangle: false,
    \\        sanitize: false,
    \\        sanitizer: null,
    \\        renderer: new marked.Renderer(),
    \\        highlight: function(code, lang) {{
    \\          if (lang && hljs.getLanguage(lang)) {{
    \\            try {{
    \\              return hljs.highlight(code, {{ language: lang }}).value;
    \\            }} catch (e) {{}}
    \\          }}
    \\          return hljs.highlightAuto(code).value;
    \\        }}
    \\      }});
    \\      
    \\      // Render markdown
    \\      const renderedView = document.getElementById('renderedView');
    \\      renderedView.innerHTML = marked.parse(rawMarkdown);
    \\      
    \\      // Apply syntax highlighting
    \\      if (typeof hljs !== 'undefined') {{
    \\        hljs.highlightAll();
    \\      }}
    \\      
    \\      // View switching
    \\      window.switchView = function(view) {{
    \\        const renderedEl = document.getElementById('renderedView');
    \\        const sourceEl = document.getElementById('sourceView');
    \\        const renderedBtn = document.getElementById('viewRendered');
    \\        const sourceBtn = document.getElementById('viewSource');
    \\        if (view === 'rendered') {{
    \\          renderedEl.classList.remove('hidden');
    \\          sourceEl.classList.remove('active');
    \\          renderedBtn.classList.add('active');
    \\          sourceBtn.classList.remove('active');
    \\          localStorage.setItem('pdf-view', 'rendered');
    \\        }} else {{
    \\          renderedEl.classList.add('hidden');
    \\          sourceEl.classList.add('active');
    \\          renderedBtn.classList.remove('active');
    \\          sourceBtn.classList.add('active');
    \\          localStorage.setItem('pdf-view', 'source');
    \\        }}
    \\      }};
    \\      
    \\      // Restore view preference
    \\      const savedView = localStorage.getItem('pdf-view');
    \\      if (savedView === 'source') {{
    \\        switchView('source');
    \\      }}
    \\      
    \\      // Theme handling
    \\      window.toggleTheme = function() {{
    \\        const isDark = document.body.classList.toggle('dark-mode');
    \\        localStorage.setItem('theme', isDark ? 'dark' : 'light');
    \\        updateThemeUI();
    \\      }};
    \\      
    \\      function updateThemeUI() {{
    \\        const isDark = document.body.classList.contains('dark-mode');
    \\        const btn = document.getElementById('themeToggle');
    \\        if (btn) {{
    \\          btn.textContent = isDark ? '\u2600\uFE0F Light' : '\uD83C\uDF19 Dark';
    \\        }}
    \\        const hljsTheme = document.getElementById('hljs-theme');
    \\        if (hljsTheme) {{
    \\          hljsTheme.href = isDark
    \\            ? 'https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github-dark.min.css'
    \\            : 'https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github.min.css';
    \\        }}
    \\      }}
    \\      
    \\      function initTheme() {{
    \\        const savedTheme = localStorage.getItem('theme');
    \\        if (savedTheme === 'dark') {{
    \\          document.body.classList.add('dark-mode');
    \\        }} else if (savedTheme === 'light') {{
    \\          document.body.classList.remove('dark-mode');
    \\        }} else if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {{
    \\          document.body.classList.add('dark-mode');
    \\        }}
    \\        updateThemeUI();
    \\      }}
    \\      
    \\      // Sidebar toggle for mobile
    \\      window.toggleSidebar = function() {{
    \\        const sidebar = document.getElementById('sidebar');
    \\        const overlay = document.getElementById('overlay');
    \\        sidebar.classList.toggle('open');
    \\        overlay.classList.toggle('show');
    \\      }};
    \\      
    \\      // Initialize theme
    \\      initTheme();
    \\    }})();
    \\  </script>
    \\</body>
    \\</html>
    ;

const pdf_fallback_template =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\  <meta name="color-scheme" content="light dark">
    \\<title>{0s} - PDF Preview</title>
    \\<style>
    \\    :root {{ --bg:#fff; --text:#24292e; --text2:#666; --border:#e2e8f0;
    \\      --hg1:#dc2626; --hg2:#b91c1c; --ht:#fff; --card-bg:#fff; --card-shadow:0 4px 24px rgba(0,0,0,.08);
    \\      --tag-bg:#fef2f2; --tag-text:#dc2626; --btn-bg:#dc2626; --btn-hover:#b91c1c; }}
    \\    @media(prefers-color-scheme:dark){{ :root {{ --bg:#0d1117; --text:#c9d1d9; --text2:#8b949e;
    \\      --border:#30363d; --hg1:#dc2626; --hg2:#b91c1c; --ht:#fff; --card-bg:#161b22;
    \\      --card-shadow:0 4px 24px rgba(0,0,0,.3); --tag-bg:#1f1315; --tag-text:#f87171;
    \\      --btn-bg:#dc2626; --btn-hover:#b91c1c; }} }}
    \\    body.dark-mode {{ --bg:#0d1117; --text:#c9d1d9; --text2:#8b949e; --border:#30363d;
    \\      --hg1:#dc2626; --hg2:#b91c1c; --ht:#fff; --card-bg:#161b22;
    \\      --card-shadow:0 4px 24px rgba(0,0,0,.3); --tag-bg:#1f1315; --tag-text:#f87171;
    \\      --btn-bg:#dc2626; --btn-hover:#b91c1c; }}
    \\    * {{ box-sizing:border-box; }} html,body {{ margin:0; padding:0; }}
    \\    body {{ font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
    \\      background:var(--bg); color:var(--text); line-height:1.6; transition:background .3s,color .3s;
    \\      display:flex; flex-direction:column; min-height:100vh; }}
    \\    .header {{ background:linear-gradient(135deg,var(--hg1),var(--hg2)); color:var(--ht);
    \\      padding:0; box-shadow:0 2px 8px rgba(0,0,0,.15); }}
    \\    .header-content {{ max-width:1400px; margin:0 auto; padding:16px 24px;
    \\      display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:12px; }}
    \\    .header-left {{ display:flex; align-items:center; gap:16px; }}
    \\    .header-title {{ font-size:1.25rem; font-weight:600; display:flex; align-items:center; gap:10px; }}
    \\    .back-btn {{ display:inline-flex; align-items:center; gap:6px; padding:8px 16px;
    \\      background:rgba(255,255,255,.15); border:1px solid rgba(255,255,255,.25);
    \\      border-radius:6px; color:var(--ht); text-decoration:none; font-size:.875rem;
    \\      font-weight:500; transition:all .2s; }}
    \\    .back-btn:hover {{ background:rgba(255,255,255,.25); transform:translateY(-1px); }}
    \\    .header-right {{ display:flex; align-items:center; gap:12px; }}
    \\    .theme-toggle {{ padding:8px 12px; background:rgba(255,255,255,.1);
    \\      border:1px solid rgba(255,255,255,.2); border-radius:6px; color:var(--ht);
    \\      font-size:.875rem; cursor:pointer; transition:all .2s; }}
    \\    .theme-toggle:hover {{ background:rgba(255,255,255,.2); }}
    \\    .center {{ flex:1; display:flex; align-items:center; justify-content:center; padding:32px; }}
    \\    .card {{ background:var(--card-bg); border-radius:16px; box-shadow:var(--card-shadow);
    \\      padding:48px; max-width:520px; width:100%; text-align:center; }}
    \\    .card-icon {{ font-size:4rem; margin-bottom:20px; }}
    \\    .card h2 {{ margin:0 0 8px; font-size:1.375rem; }}
    \\    .card .filename {{ color:var(--text2); font-size:.875rem; word-break:break-all; margin-bottom:4px; }}
    \\    .card .meta {{ color:var(--text2); font-size:.8125rem; margin-bottom:20px; }}
    \\    .tag {{ display:inline-block; padding:4px 12px; background:var(--tag-bg); color:var(--tag-text);
    \\      border-radius:20px; font-size:.75rem; font-weight:600; margin-bottom:20px; }}
    \\    .desc {{ color:var(--text2); font-size:.875rem; line-height:1.6; margin-bottom:24px; }}
    \\    .download-btn {{ display:inline-flex; align-items:center; gap:8px; padding:12px 32px;
    \\      background:var(--btn-bg); color:#fff; border:none; border-radius:10px; font-size:.9375rem;
    \\      font-weight:600; cursor:pointer; text-decoration:none; transition:all .2s;
    \\      box-shadow:0 2px 8px rgba(220,38,38,.3); }}
    \\    .download-btn:hover {{ background:var(--btn-hover); transform:translateY(-1px);
    \\      box-shadow:0 4px 12px rgba(220,38,38,.4); }}
    \\    @media(max-width:640px) {{ .header-content {{ padding:12px 16px; }} .header-title {{ font-size:1rem; }}
    \\      .card {{ padding:32px 24px; }} .card-icon {{ font-size:3rem; }} }}
    \\</style></head><body>
    \\  <header class="header"><div class="header-content">
    \\    <div class="header-left">
    \\      <a href="{1s}" class="back-btn"><span>&larr;</span> Back</a>
    \\      <div class="header-title"><span>&#x1F4D5;</span><span>{2s}</span></div>
    \\    </div>
    \\    <div class="header-right">
    \\      <button class="theme-toggle" onclick="toggleTheme()" id="themeToggle">&#x1F319; Dark</button>
    \\    </div>
    \\  </div></header>
    \\  <div class="center"><div class="card">
    \\    <div class="card-icon">&#x1F4D5;</div>
    \\    <h2>{2s}</h2>
    \\    <div class="meta">{3s}</div>
    \\    <div class="tag">PDF Document</div>
    \\    <div class="desc">
    \\      {4s}
    \\    </div>
    \\    <a href="/download?file={5s}" class="download-btn">&#x2B07; Download PDF</a>
    \\  </div></div>
    \\<script>
    \\function toggleTheme(){{var d=document.body.classList.toggle('dark-mode');localStorage.setItem('theme',d?'dark':'light');updateUI()}}
    \\function updateUI(){{var d=document.body.classList.contains('dark-mode');var b=document.getElementById('themeToggle');if(b)b.textContent=d?'\\u2600\\uFE0F Light':'\\u1F319 Dark'}}
    \\(function(){{var s=localStorage.getItem('theme');if(s==='dark')document.body.classList.add('dark-mode');else if(!s&&window.matchMedia('(prefers-color-scheme:dark)').matches)document.body.classList.add('dark-mode');updateUI()}})()
    \\</script></body></html>
    ;
