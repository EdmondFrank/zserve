const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");

/// OLE2 compound document magic bytes
const OLE2_MAGIC = [_]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };

/// Check if a MIME type represents a legacy Office file (.doc/.xls/.ppt)
pub fn isLegacyOfficeFile(mime_type: []const u8) bool {
    return std.mem.eql(u8, mime_type, "application/msword") or
        std.mem.eql(u8, mime_type, "application/vnd.ms-excel") or
        std.mem.eql(u8, mime_type, "application/vnd.ms-powerpoint");
}

/// Render a legacy Office file preview
pub fn renderLegacyPreview(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    file: Io.File,
    mime_type: []const u8,
    file_path: []const u8,
    dir_path: []const u8,
    file_size: u64,
) !void {
    const file_bytes = try allocator.alloc(u8, @intCast(file_size));
    defer allocator.free(file_bytes);

    var pos: usize = 0;
    while (pos < file_size) {
        const n = file.readPositionalAll(io, file_bytes[pos..], pos) catch break;
        if (n == 0) break;
        pos += n;
    }

    if (std.mem.eql(u8, mime_type, "application/msword")) {
        try renderDocPreview(io, allocator, stream, file_bytes[0..pos], file_path, dir_path, file_size);
    } else {
        // .xls and .ppt — show info page with download
        const format = if (std.mem.eql(u8, mime_type, "application/vnd.ms-excel")) "XLS Spreadsheet" else "PPT Presentation";
        try renderLegacyFallback(io, allocator, stream, file_path, dir_path, file_size, format);
    }
}

/// Extract readable text from a .doc (OLE2) binary file.
/// Strategy: scan for UTF-16LE text runs of printable characters.
fn extractDocText(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    // Verify OLE2 magic
    if (data.len < 8 or !std.mem.eql(u8, data[0..8], &OLE2_MAGIC)) {
        return error.NotOLE2;
    }

    var text = std.ArrayList(u8).initCapacity(allocator, data.len / 4) catch return error.OutOfMemory;
    errdefer text.deinit(allocator);

    var i: usize = 0;
    var in_run = false;
    var run_start: usize = 0;

    // Scan for UTF-16LE character pairs
    while (i + 1 < data.len) : (i += 2) {
        const lo = data[i];
        const hi = data[i + 1];
        const codepoint: u16 = @as(u16, lo) | (@as(u16, hi) << 8);

        const valid = isValidUtf16Char(codepoint);

        if (valid) {
            if (!in_run) {
                run_start = i;
                in_run = true;
            }
        } else {
            if (in_run) {
                const run_len = i - run_start;
                if (run_len >= 4) { // Minimum 2 UTF-16 characters
                    try appendUtf16LeRun(&text, allocator, data[run_start..i]);
                }
                in_run = false;
            }
        }
    }

    // Handle final run
    if (in_run) {
        const run_len = data.len - run_start;
        if (run_len >= 4) {
            try appendUtf16LeRun(&text, allocator, data[run_start..]);
        }
    }

    if (text.items.len == 0) return error.NoTextFound;
    return text.toOwnedSlice(allocator);
}

/// Check if a UTF-16 code unit is a valid printable character
fn isValidUtf16Char(c: u16) bool {
    // Exclude control characters (except \t \n \r), surrogates, and some specials
    if (c < 0x0020) {
        return c == '\t' or c == '\n' or c == '\r';
    }
    // Surrogates
    if (c >= 0xD800 and c <= 0xDFFF) return false;
    // Specials block
    if (c >= 0xFFF0 and c <= 0xFFFF) return false;
    // Common OLE2 junk bytes
    if (c == 0x0000) return false;
    if (c == 0x0001) return false; // SOH
    if (c == 0x0007) return false; // BEL (field markers)
    if (c == 0x0013) return false; // field markers
    if (c == 0x0014) return false;
    return true;
}

/// Append a UTF-16LE text run to the output buffer, converting to UTF-8
fn appendUtf16LeRun(out: *std.ArrayList(u8), allocator: std.mem.Allocator, run: []const u8) !void {
    var i: usize = 0;
    while (i + 1 < run.len) : (i += 2) {
        const lo = run[i];
        const hi = run[i + 1];
        const cp: u21 = @as(u21, lo) | (@as(u21, hi) << 8);

        // Encode as UTF-8
        if (cp < 0x80) {
            try out.append(allocator, @intCast(cp));
        } else if (cp < 0x800) {
            try out.append(allocator, @intCast(0xC0 | (cp >> 6)));
            try out.append(allocator, @intCast(0x80 | (cp & 0x3F)));
        } else {
            try out.append(allocator, @intCast(0xE0 | (cp >> 12)));
            try out.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3F)));
            try out.append(allocator, @intCast(0x80 | (cp & 0x3F)));
        }
    }
}

/// Render .doc preview with extracted text
fn renderDocPreview(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    file_bytes: []const u8,
    file_path: []const u8,
    dir_path: []const u8,
    file_size: u64,
) !void {
    const raw_text = extractDocText(allocator, file_bytes) catch {
        const format = "DOC Document";
        try renderLegacyFallback(io, allocator, stream, file_path, dir_path, file_size, format);
        return;
    };
    defer allocator.free(raw_text);

    // Clean up extracted text: collapse multiple blank lines, trim
    var cleaned = std.ArrayList(u8).initCapacity(allocator, raw_text.len) catch return;
    defer cleaned.deinit(allocator);

    var blank_count: usize = 0;
    for (raw_text) |c| {
        if (c == '\n') {
            blank_count += 1;
            if (blank_count <= 2) {
                cleaned.append(allocator, c) catch break;
            }
        } else {
            blank_count = 0;
            cleaned.append(allocator, c) catch break;
        }
    }

    // HTML-escape the text
    const escaped = try htmlEscape(allocator, cleaned.items);
    defer allocator.free(escaped);

    const filename = std.fs.path.basename(file_path);
    const parent_dir = buildParentDir(allocator, dir_path);
    defer if (parent_dir.len > 1 and !std.mem.startsWith(u8, dir_path, "/")) allocator.free(parent_dir);

    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, file_size);

    var write_buf: [65536]u8 = undefined;
    var writer = stream.writer(io, &write_buf);

    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n");

    const html = try std.fmt.allocPrint(allocator, doc_legacy_template, .{
        filename, parent_dir, filename, size_str, escaped,
    });
    defer allocator.free(html);

    try writer.interface.writeAll(html);
    try writer.interface.flush();
}

/// Render a fallback info page for legacy formats that can't be previewed
fn renderLegacyFallback(
    io: Io,
    allocator: std.mem.Allocator,
    stream: Io.net.Stream,
    file_path: []const u8,
    dir_path: []const u8,
    file_size: u64,
    format: []const u8,
) !void {
    const filename = std.fs.path.basename(file_path);
    const parent_dir = buildParentDir(allocator, dir_path);
    defer if (parent_dir.len > 1 and !std.mem.startsWith(u8, dir_path, "/")) allocator.free(parent_dir);

    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, file_size);

    const html = try std.fmt.allocPrint(allocator, legacy_fallback_template, .{
        filename, parent_dir, filename, filename, size_str, format, format, file_path,
    });
    defer allocator.free(html);

    var write_buf: [65536]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n");
    try writer.interface.writeAll(html);
    try writer.interface.flush();
}

const doc_legacy_template =
    \\<!DOCTYPE html>
    \\<html lang="en"><head>
    \\  <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\  <meta name="color-scheme" content="light dark">
    \\<title>{s} - Document Preview</title>
    \\<style>
    \\    :root {{ --bg:#fff; --text:#24292e; --text2:#666; --border:#e2e8f0;
    \\      --hg1:#2563eb; --hg2:#1d4ed8; --ht:#fff; --sb:#f8fafc; --mbg:#f8fafc;
    \\      --cbg:#f6f8fa; --cb:#d0d7de; --inv:#f1f5f9; --warn:#f59e0b; }}
    \\    @media(prefers-color-scheme:dark){{ :root {{ --bg:#0d1117; --text:#c9d1d9; --text2:#8b949e;
    \\      --border:#30363d; --hg1:#2563eb; --hg2:#1d4ed8; --ht:#fff; --sb:#161b22; --mbg:#161b22;
    \\      --cbg:#161b22; --cb:#30363d; --inv:#21262d; --warn:#f59e0b; }} }}
    \\    body.dark-mode {{ --bg:#0d1117; --text:#c9d1d9; --text2:#8b949e; --border:#30363d;
    \\      --hg1:#2563eb; --hg2:#1d4ed8; --ht:#fff; --sb:#161b22; --mbg:#161b22;
    \\      --cbg:#161b22; --cb:#30363d; --inv:#21262d; --warn:#f59e0b; }}
    \\    * {{ box-sizing:border-box; }} html,body {{ margin:0; padding:0; }}
    \\    body {{ font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
    \\      background:var(--bg); color:var(--text); line-height:1.6; transition:background .3s,color .3s; }}
    \\    .header {{ background:linear-gradient(135deg,var(--hg1),var(--hg2)); color:var(--ht);
    \\      padding:0; box-shadow:0 2px 8px rgba(0,0,0,.15); position:sticky; top:0; z-index:100; }}
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
    \\    .container {{ max-width:1400px; margin:0 auto; display:flex; min-height:calc(100vh - 64px); }}
    \\    .sidebar {{ width:280px; flex-shrink:0; background:var(--sb); border-right:1px solid var(--border);
    \\      padding:20px; overflow-y:auto; max-height:calc(100vh - 64px); position:sticky; top:64px; }}
    \\    .sidebar-section {{ margin-bottom:24px; }}
    \\    .sidebar-title {{ font-size:.75rem; font-weight:600; text-transform:uppercase;
    \\      letter-spacing:.05em; color:var(--text2); margin-bottom:12px; padding-bottom:8px;
    \\      border-bottom:1px solid var(--border); }}
    \\    .file-meta {{ background:var(--mbg); border-radius:8px; padding:12px; font-size:.8125rem; }}
    \\    .file-meta-item {{ display:flex; justify-content:space-between; padding:4px 0;
    \\      border-bottom:1px solid var(--border); }}
    \\    .file-meta-item:last-child {{ border-bottom:none; }}
    \\    .file-meta-label {{ color:var(--text2); }}
    \\    .file-meta-value {{ font-weight:500; color:var(--text); }}
    \\    .notice {{ background:rgba(245,158,11,.1); border:1px solid rgba(245,158,11,.3);
    \\      border-radius:8px; padding:12px 16px; margin-bottom:20px; font-size:.8125rem;
    \\      color:var(--warn); display:flex; align-items:center; gap:8px; }}
    \\    .main {{ flex:1; padding:32px 40px; max-width:900px; }}
    \\    .doc-body {{ font-size:15px; line-height:1.8; white-space:pre-wrap; word-wrap:break-word;
    \\      color:var(--text); background:var(--cbg); border:1px solid var(--cb);
    \\      border-radius:8px; padding:24px 32px; }}
    \\    @media(max-width:1024px) {{ .sidebar {{ display:none; }} .main {{ padding:24px; max-width:100%; }} }}
    \\    @media(max-width:640px) {{ .header-content {{ padding:12px 16px; }} .header-title {{ font-size:1rem; }}
    \\      .main {{ padding:16px; }} }}
    \\</style></head><body>
    \\  <header class="header"><div class="header-content">
    \\    <div class="header-left">
    \\      <a href="{s}" class="back-btn"><span>&larr;</span> Back to directory</a>
    \\      <div class="header-title"><span>&#x1F4DD;</span><span>{s}</span></div>
    \\    </div>
    \\    <div class="header-right">
    \\      <button class="theme-toggle" onclick="toggleTheme()" id="themeToggle">&#x1F319; Dark</button>
    \\    </div>
    \\  </div></header>
    \\  <div class="container">
    \\    <aside class="sidebar"><div class="sidebar-section">
    \\      <div class="sidebar-title">File Info</div>
    \\      <div class="file-meta">
    \\        <div class="file-meta-item"><span class="file-meta-label">Size</span><span class="file-meta-value">{s}</span></div>
    \\        <div class="file-meta-item"><span class="file-meta-label">Type</span><span class="file-meta-value">DOC Document (legacy)</span></div>
    \\      </div>
    \\    </div></aside>
    \\    <main class="main">
    \\      <div class="notice">&#x26A0;&#xFE0F; Legacy .doc format — text extracted from binary. Formatting is not preserved.</div>
    \\      <div class="doc-body">{s}</div>
    \\    </main>
    \\  </div>
    \\<script>
    \\function toggleTheme(){{var d=document.body.classList.toggle('dark-mode');localStorage.setItem('theme',d?'dark':'light');updateUI()}}
    \\function updateUI(){{var d=document.body.classList.contains('dark-mode');var b=document.getElementById('themeToggle');if(b)b.textContent=d?'\u2600\uFE0F Light':'\u1F319 Dark'}}
    \\(function(){{var s=localStorage.getItem('theme');if(s==='dark')document.body.classList.add('dark-mode');else if(!s&&window.matchMedia('(prefers-color-scheme:dark)').matches)document.body.classList.add('dark-mode');updateUI()}})()
    \\</script></body></html>
    ;

const legacy_fallback_template =
    \\<!DOCTYPE html>
    \\<html lang="en"><head>
    \\  <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\  <meta name="color-scheme" content="light dark">
    \\<title>{s} - Office Preview</title>
    \\<style>
    \\    :root {{ --bg:#fff; --text:#24292e; --text2:#666; --border:#e2e8f0;
    \\      --hg1:#6366f1; --hg2:#4f46e5; --ht:#fff; --card-bg:#fff; --card-shadow:0 4px 24px rgba(0,0,0,.08);
    \\      --tag-bg:#eef2ff; --tag-text:#4f46e5; --btn-bg:#4f46e5; --btn-hover:#4338ca; }}
    \\    @media(prefers-color-scheme:dark){{ :root {{ --bg:#0d1117; --text:#c9d1d9; --text2:#8b949e;
    \\      --border:#30363d; --hg1:#6366f1; --hg2:#4f46e5; --ht:#fff; --card-bg:#161b22;
    \\      --card-shadow:0 4px 24px rgba(0,0,0,.3); --tag-bg:#1e1b4b; --tag-text:#a5b4fc;
    \\      --btn-bg:#4f46e5; --btn-hover:#4338ca; }} }}
    \\    body.dark-mode {{ --bg:#0d1117; --text:#c9d1d9; --text2:#8b949e; --border:#30363d;
    \\      --hg1:#6366f1; --hg2:#4f46e5; --ht:#fff; --card-bg:#161b22;
    \\      --card-shadow:0 4px 24px rgba(0,0,0,.3); --tag-bg:#1e1b4b; --tag-text:#a5b4fc;
    \\      --btn-bg:#4f46e5; --btn-hover:#4338ca; }}
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
    \\      box-shadow:0 2px 8px rgba(79,70,229,.3); }}
    \\    .download-btn:hover {{ background:var(--btn-hover); transform:translateY(-1px);
    \\      box-shadow:0 4px 12px rgba(79,70,229,.4); }}
    \\    .tip {{ margin-top:20px; font-size:.75rem; color:var(--text2); }}
    \\    .tip code {{ background:var(--tag-bg); color:var(--tag-text); padding:2px 6px; border-radius:4px; }}
    \\    @media(max-width:640px) {{ .header-content {{ padding:12px 16px; }} .header-title {{ font-size:1rem; }}
    \\      .card {{ padding:32px 24px; }} .card-icon {{ font-size:3rem; }} }}
    \\</style></head><body>
    \\  <header class="header"><div class="header-content">
    \\    <div class="header-left">
    \\      <a href="{s}" class="back-btn"><span>&larr;</span> Back</a>
    \\      <div class="header-title"><span>&#x1F4E5;</span><span>{s}</span></div>
    \\    </div>
    \\    <div class="header-right">
    \\      <button class="theme-toggle" onclick="toggleTheme()" id="themeToggle">&#x1F319; Dark</button>
    \\    </div>
    \\  </div></header>
    \\  <div class="center"><div class="card">
    \\    <div class="card-icon">&#x1F4C4;</div>
    \\    <h2>{s}</h2>
    \\    <div class="meta">{s} &bull; {s}</div>
    \\    <div class="tag">Legacy Binary Format</div>
    \\    <div class="desc">
    \\      This file uses the legacy Microsoft Office binary format. Online preview is not available for
    \\      <strong>{s}</strong> files. Download the file to view it in Microsoft Office or a compatible application.
    \\    </div>
    \\    <a href="/download?file={s}" class="download-btn">&#x2B07; Download File</a>
    \\    <div class="tip">Tip: Save as <code>.xlsx</code> / <code>.docx</code> / <code>.pptx</code> for in-browser preview support.</div>
    \\  </div></div>
    \\<script>
    \\function toggleTheme(){{var d=document.body.classList.toggle('dark-mode');localStorage.setItem('theme',d?'dark':'light');updateUI()}}
    \\function updateUI(){{var d=document.body.classList.contains('dark-mode');var b=document.getElementById('themeToggle');if(b)b.textContent=d?'\u2600\uFE0F Light':'\u1F319 Dark'}}
    \\(function(){{var s=localStorage.getItem('theme');if(s==='dark')document.body.classList.add('dark-mode');else if(!s&&window.matchMedia('(prefers-color-scheme:dark)').matches)document.body.classList.add('dark-mode');updateUI()}})()
    \\</script></body></html>
    ;

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

fn htmlEscape(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var count: usize = 0;
    for (input) |c| {
        switch (c) {
            '&' => count += 4,
            '<' => count += 3,
            '>' => count += 3,
            '"' => count += 5,
            else => {},
        }
    }
    if (count == 0) return input;

    const result = try allocator.alloc(u8, input.len + count);
    var j: usize = 0;
    for (input) |c| {
        switch (c) {
            '&' => { @memcpy(result[j .. j + 5], "&amp;"); j += 5; },
            '<' => { @memcpy(result[j .. j + 4], "&lt;"); j += 4; },
            '>' => { @memcpy(result[j .. j + 4], "&gt;"); j += 4; },
            '"' => { @memcpy(result[j .. j + 6], "&quot;"); j += 6; },
            else => { result[j] = c; j += 1; },
        }
    }
    return result;
}
